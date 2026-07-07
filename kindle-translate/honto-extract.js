#!/usr/bin/env node
// honto-extract.js — Extract text from HONTO browser viewer via Playwright
//
// Usage:
//   node honto-extract.js --slug <name> --book-url <honto-product-url> [--max-pages 50]
//   node honto-extract.js --slug <name> --reader-only [--max-pages 50]
//
// Flags:
//   --book-url <url>   HONTO product URL (e.g., https://honto.jp/ebook/pd_34077570.html)
//   --slug <name>      Output directory name (required)
//   --max-pages <n>    Safety limit (default 50)
//   --reader-only      Skip product page, go straight to My本棚 and let user select

const fs = require('fs');
const path = require('path');
const readline = require('readline');

// Resolve playwright: try local node_modules first, then global
let playwright;
try {
  playwright = require('playwright');
} catch {
  const globalRoot = require('child_process')
    .execSync('npm root -g', { encoding: 'utf8' })
    .trim();
  playwright = require(path.join(globalRoot, 'playwright'));
}
const { chromium } = playwright;

// ---------------------------------------------------------------------------
// CLI parsing
// ---------------------------------------------------------------------------
function parseArgs() {
  const args = process.argv.slice(2);
  const opts = { maxPages: 50, readerOnly: false };

  for (let i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--book-url':
        opts.bookUrl = args[++i];
        break;
      case '--slug':
        opts.slug = args[++i];
        break;
      case '--max-pages':
        opts.maxPages = parseInt(args[++i], 10);
        break;
      case '--reader-only':
        opts.readerOnly = true;
        break;
      case '--title':
        opts.title = args[++i];
        break;
      default:
        console.error(`Unknown flag: ${args[i]}`);
        process.exit(1);
    }
  }

  if (!opts.slug) {
    console.error('ERROR: --slug is required');
    console.error('Usage: node honto-extract.js --book-url <url> --slug <name>');
    console.error('       node honto-extract.js --slug <name> --reader-only');
    process.exit(1);
  }
  if (!opts.bookUrl && !opts.readerOnly) {
    console.error('ERROR: one of --book-url or --reader-only is required');
    process.exit(1);
  }
  return opts;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
const USER_DATA_DIR = '/tmp/honto-playwright-profile';

function log(msg) {
  const ts = new Date().toLocaleTimeString('ja-JP', { hour12: false });
  console.log(`[${ts}] ${msg}`);
}

function promptUser(question) {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  return new Promise((resolve) => {
    rl.question(question, (answer) => {
      rl.close();
      resolve(answer);
    });
  });
}

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

function padPage(n) {
  return String(n).padStart(3, '0');
}

async function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

// ---------------------------------------------------------------------------
// Login detection
// ---------------------------------------------------------------------------
async function handleLoginIfNeeded(page) {
  const loginSelectors = [
    'input[name="loginId"]',
    'input[name="password"]',
    '#loginId',
    '#password',
    'form[action*="login"]',
  ];

  function isLoginUrl(u) {
    return u.includes('/login') || u.includes('/sso') || u.includes('/dy/login');
  }

  let isLogin = isLoginUrl(page.url());
  if (!isLogin) {
    for (const sel of loginSelectors) {
      if (await page.$(sel)) { isLogin = true; break; }
    }
  }

  if (!isLogin) return false;

  log('Login page detected. Please log in via the browser window...');
  await page.screenshot({ path: '/tmp/honto-extract-login.png' });

  const maxWait = 120000;
  const poll = 3000;
  let elapsed = 0;
  while (elapsed < maxWait) {
    await sleep(poll);
    elapsed += poll;
    const u = page.url();
    if (!isLoginUrl(u)) {
      let stillLogin = false;
      for (const sel of loginSelectors) {
        if (await page.$(sel)) { stillLogin = true; break; }
      }
      if (!stillLogin) {
        log('Login completed.');
        await sleep(2000);
        return true;
      }
    }
    if (elapsed % 15000 === 0) log(`Waiting for login... (${elapsed / 1000}s)`);
  }
  log('WARNING: Login wait timed out after 120s. Continuing anyway.');
  return true;
}

// ---------------------------------------------------------------------------
// Step 1: Navigate to book and open browser viewer
// ---------------------------------------------------------------------------
async function openBookInViewer(page, opts) {
  if (opts.readerOnly) {
    log('Reader-only mode: navigating to My本棚...');
    await page.goto('https://honto.jp/my/shelf.html', {
      waitUntil: 'domcontentloaded',
      timeout: 30000,
    });
    await handleLoginIfNeeded(page);
    await sleep(3000);
    await page.screenshot({ path: '/tmp/honto-extract-shelf.png' });

    // Click each book cover until we find our target, then click "ブラウザで読む"
    log('Looking for target book on shelf...');
    const coverImgs = await page.$$('.stShelfList img, .stContentsArea img, [class*="shelf"] img, [class*="book"] img').catch(() => []);
    log(`Found ${coverImgs.length} book images on shelf.`);

    let viewerButtonClicked = false;
    for (let i = 0; i < coverImgs.length && !viewerButtonClicked; i++) {
      try {
        log(`Trying book ${i + 1}/${coverImgs.length}...`);
        await coverImgs[i].click();
        await sleep(2000);

        // Check if popup appeared with book title or "ブラウザで読む"
        const browserBtn = await page.$('a:has-text("ブラウザで読む"), button:has-text("ブラウザで読む")');
        if (browserBtn && await browserBtn.isVisible().catch(() => false)) {
          // Check popup text for our book title
          const popupText = await page.evaluate(() => {
            const popup = document.querySelector('[class*="popup"], [class*="modal"], [class*="overlay"], [class*="balloon"]');
            return popup ? popup.innerText : document.body.innerText.substring(0, 500);
          }).catch(() => '');

          log(`Popup text preview: "${popupText.substring(0, 80).replace(/\n/g, ' ')}"`);

          // If --title given, check popup text matches
          if (opts.title && !popupText.includes(opts.title)) {
            log(`Book "${popupText.substring(0, 30).replace(/\n/g, ' ')}" doesn't match title "${opts.title}", skipping...`);
            await page.keyboard.press('Escape');
            await sleep(500);
            continue;
          }

          log('Clicking "ブラウザで読む"...');
          const [newPage] = await Promise.all([
            page.context().waitForEvent('page', { timeout: 10000 }).catch(() => null),
            browserBtn.click(),
          ]);
          if (newPage) {
            log('Viewer opened in new tab!');
            opts._viewerPage = newPage;
            await newPage.waitForLoadState('domcontentloaded', { timeout: 30000 }).catch(() => {});
            viewerButtonClicked = true;
          }
          await sleep(3000);
          break;
        } else {
          // Dismiss popup by pressing Escape
          await page.keyboard.press('Escape');
          await sleep(500);
        }
      } catch { /* next book */ }
    }

    // Now poll for viewer tab (mobilebook.jp domain)
    log('Polling for viewer tab (mobilebook.jp)...');
    const maxWait = 60000;
    const poll = 2000;
    let elapsed = 0;
    while (elapsed < maxWait) {
      await sleep(poll);
      elapsed += poll;
      const pages = page.context().pages();
      for (const p of pages) {
        const u = p.url();
        if (u.includes('mobilebook.jp') || u.includes('viewer')) {
          log(`Viewer tab found: ${u.substring(0, 80)}...`);
          opts._viewerPage = p;
          await sleep(5000);
          return;
        }
      }
      // Also check if current page navigated to viewer
      if (page.url().includes('mobilebook.jp') || page.url().includes('viewer')) {
        log('Viewer loaded in current tab.');
        return;
      }
      if (elapsed % 10000 === 0) log(`Waiting for viewer... (${elapsed / 1000}s)`);
    }
    log('WARNING: Viewer wait timed out.');
    await page.screenshot({ path: '/tmp/honto-extract-shelf-timeout.png' });
    return;
  }

  log(`Navigating to product page: ${opts.bookUrl}`);
  await page.goto(opts.bookUrl, {
    waitUntil: 'domcontentloaded',
    timeout: 30000,
  });
  await handleLoginIfNeeded(page);
  await sleep(3000);

  log('On product page. Looking for browser viewer button...');
  await page.screenshot({ path: '/tmp/honto-extract-product.png' });

  // Strategies to find and click the "ブラウザで読む" (read in browser) button
  const viewerButtonSelectors = [
    // Direct text match for browser viewer button
    'a:has-text("ブラウザで読む")',
    'button:has-text("ブラウザで読む")',
    'a:has-text("ブラウザビューア")',
    'button:has-text("ブラウザビューア")',
    // "読む" (read) buttons that may lead to viewer
    'a:has-text("今すぐ読む")',
    'a:has-text("読む")',
    // HONTO viewer-specific link patterns
    'a[href*="booklive"]',
    'a[href*="viewer"]',
    'a[href*="browser"]',
    'a[href*="read"]',
    // Purchase page "読む" area
    '.stBtn a:has-text("読む")',
    '.p-shelfBookAction a',
    // My本棚 link from purchase confirmation
    'a[href*="shelf"]',
  ];

  let viewerOpened = false;

  for (const sel of viewerButtonSelectors) {
    try {
      const btn = await page.$(sel);
      if (btn) {
        const visible = await btn.isVisible();
        if (!visible) continue;

        const btnText = await btn.innerText().catch(() => sel);
        const href = await btn.getAttribute('href').catch(() => '');
        log(`Found button: "${btnText.trim().substring(0, 40)}" (href: ${href || 'none'}) — clicking...`);

        // Check if it opens a new tab/window
        const [newPage] = await Promise.all([
          page.context().waitForEvent('page', { timeout: 8000 }).catch(() => null),
          btn.click(),
        ]);

        if (newPage) {
          log('Browser viewer opened in new tab. Switching to it...');
          await newPage.waitForLoadState('domcontentloaded', { timeout: 30000 });
          // Replace page reference — caller needs to use the returned page
          viewerOpened = true;
          // Store new page on opts for the caller
          opts._viewerPage = newPage;
          break;
        }

        await sleep(3000);

        // Check if we navigated to a viewer
        const currentUrl = page.url();
        if (
          currentUrl.includes('viewer') ||
          currentUrl.includes('booklive') ||
          currentUrl.includes('read') ||
          currentUrl.includes('browser')
        ) {
          log(`Navigated to viewer: ${currentUrl}`);
          viewerOpened = true;
          break;
        }

        // Check if login was required
        const loggedIn = await handleLoginIfNeeded(page);
        if (loggedIn) {
          // After login, might need to re-navigate
          await sleep(2000);
          const afterLoginUrl = page.url();
          if (
            afterLoginUrl.includes('viewer') ||
            afterLoginUrl.includes('read')
          ) {
            viewerOpened = true;
            break;
          }
        }
      }
    } catch {
      // Selector did not match, try next
    }
  }

  if (!viewerOpened) {
    log('Could not auto-detect browser viewer button. Trying My本棚 → open from there...');
    await page.screenshot({ path: '/tmp/honto-extract-product-nobutton.png' });
    // Navigate to shelf and try to open from there
    await page.goto('https://honto.jp/my/shelf.html', { waitUntil: 'domcontentloaded', timeout: 30000 });
    await handleLoginIfNeeded(page);
    await sleep(3000);
    log('On My本棚. Polling for viewer tab...');
    const maxWait = 120000;
    const poll = 3000;
    let elapsed = 0;
    while (elapsed < maxWait) {
      await sleep(poll);
      elapsed += poll;
      const pages = page.context().pages();
      if (pages.length > 1) {
        const lastPage = pages[pages.length - 1];
        if (lastPage !== page) {
          log('Viewer tab detected. Switching...');
          opts._viewerPage = lastPage;
          break;
        }
      }
      const u = page.url();
      if (u.includes('viewer') || u.includes('mobilebook')) {
        log('Viewer loaded in current tab.');
        break;
      }
      if (elapsed % 15000 === 0) log(`Waiting for viewer... (${elapsed / 1000}s)`);
    }
  }
}

// ---------------------------------------------------------------------------
// Step 2: Wait for viewer to load and extract text
// ---------------------------------------------------------------------------
async function extractFromViewer(page, opts) {
  const outDir = `/tmp/kindle-translate/${opts.slug}/raw`;
  ensureDir(outDir);

  // Use viewer page if it was opened in a new tab
  const viewerPage = opts._viewerPage || page;

  log('Waiting for browser viewer to fully load...');
  await sleep(5000);

  let viewerUrl = viewerPage.url();
  log(`Viewer URL: ${viewerUrl}`);

  // Validate we're actually on the viewer, not still on the shelf
  if (viewerUrl.includes('honto.jp/my/shelf') || viewerUrl.includes('honto.jp/ebook/pd_')) {
    log('ERROR: Still on shelf/product page, not in viewer. Aborting.');
    await viewerPage.screenshot({ path: '/tmp/honto-extract-not-viewer.png' });
    throw new Error('Failed to open viewer. Please open the book manually in the browser viewer first, then re-run with --reader-only.');
  }

  await viewerPage.screenshot({ path: '/tmp/honto-extract-viewer-initial.png' });

  // Dump top-level DOM for debugging
  try {
    const domDump = await viewerPage.evaluate(() => {
      const els = document.querySelectorAll('body > *');
      return Array.from(els).slice(0, 20).map(e =>
        `<${e.tagName.toLowerCase()} id="${e.id || ''}" class="${(e.className || '').toString().substring(0,80)}">`
      ).join('\n');
    });
    log(`DOM structure:\n${domDump}`);
  } catch { /* ok */ }

  // Detect viewer type and wait for content
  // BinB-specific selectors first (HONTO's actual viewer engine)
  const viewerSelectors = [
    '#content_p',
    '#content',
    '#binb',
    'div[class*="binb"]',
    '.pager-area',
    // iframe-based viewer
    'iframe',
    // Canvas-based renderer
    'canvas',
    // HONTO EPUB viewer content containers
    'div[class*="content"]',
    'div[class*="reader"]',
    'div[class*="viewer"]',
    'div[class*="book"]',
    'div[class*="page"]',
    // Generic text containers
    'div[id*="content"]',
    'div[id*="reader"]',
    'div[id*="viewer"]',
    'div[id*="page"]',
    // Epub.js / readium containers
    '#epub-viewer',
    '#reader-viewport',
    '.epub-container',
  ];

  let detectedSelector = null;
  let viewerType = 'unknown';

  for (const sel of viewerSelectors) {
    try {
      const el = await viewerPage.waitForSelector(sel, { timeout: 5000 });
      if (el) {
        const tagName = await el.evaluate((e) => e.tagName.toLowerCase());
        if (tagName === 'iframe') {
          viewerType = 'iframe';
        } else if (tagName === 'canvas') {
          viewerType = 'canvas';
        } else {
          viewerType = 'dom';
        }
        detectedSelector = sel;
        log(`Viewer container detected (${viewerType}): ${sel}`);
        break;
      }
    } catch {
      // Try next
    }
  }

  if (!detectedSelector) {
    log('WARNING: No known viewer container detected. Will attempt generic extraction.');
    await viewerPage.screenshot({ path: '/tmp/honto-extract-viewer-nocontainer.png' });
    log('Screenshot saved: /tmp/honto-extract-viewer-nocontainer.png');
  }

  // Dismiss any overlay/settings panel that may be open
  log('Dismissing any overlay panels...');
  try {
    // Try clicking a "確定" (confirm) or close button on settings panel
    for (const sel of ['button:has-text("確定")', 'a:has-text("確定")', '[class*="close"]', 'button:has-text("閉じる")']) {
      const btn = await viewerPage.$(sel);
      if (btn && await btn.isVisible().catch(() => false)) {
        log(`Closing overlay via: ${sel}`);
        await btn.click();
        await sleep(1000);
        break;
      }
    }
    // Press Escape to dismiss any remaining overlay
    await viewerPage.keyboard.press('Escape');
    await sleep(1000);
    // Click center of page to focus the reader and dismiss tooltips
    const vp = viewerPage.viewportSize();
    if (vp) {
      await viewerPage.mouse.click(vp.width * 0.5, vp.height * 0.5);
      await sleep(1000);
    }
  } catch { /* continue */ }

  await viewerPage.screenshot({ path: '/tmp/honto-extract-viewer-after-dismiss.png' });

  // Extra wait for dynamic content loading
  await sleep(3000);

  // ---------------------------------------------------------------------------
  // Screenshot-only extraction loop (BinB reader uses font obfuscation DRM)
  // ---------------------------------------------------------------------------
  log(`Starting screenshot extraction (max ${opts.maxPages} pages)...`);
  log('BinB reader uses font obfuscation — capturing screenshots for OCR.');

  let pageNum = 0;
  let prevScreenshotSize = 0;
  let prevScreenshotHash = -1;
  let staleCount = 0;
  const MAX_STALE = 3;

  while (pageNum < opts.maxPages) {
    pageNum++;

    const ssPath = path.join(outDir, `page-${padPage(pageNum)}.png`);
    await viewerPage.screenshot({ path: ssPath, fullPage: false });
    const ssBuffer = fs.readFileSync(ssPath);
    const ssSize = ssBuffer.length;
    // Simple hash: sum of every 100th byte for quick comparison
    let ssHash = 0;
    for (let i = 0; i < ssBuffer.length; i += 100) ssHash += ssBuffer[i];

    // Detect end: if screenshot hash matches previous (same visual content)
    if (prevScreenshotSize > 0 && ssHash === prevScreenshotHash && Math.abs(ssSize - prevScreenshotSize) < 2000) {
      staleCount++;
      log(`Page ${padPage(pageNum)}: [screenshot ~same size as prev, stale ${staleCount}/${MAX_STALE}]`);
      if (staleCount >= MAX_STALE) {
        // Remove stale screenshots
        for (let i = 0; i < MAX_STALE; i++) {
          const stalePath = path.join(outDir, `page-${padPage(pageNum - i)}.png`);
          try { fs.unlinkSync(stalePath); } catch {}
        }
        pageNum -= MAX_STALE;
        log(`End of book detected. Final page count: ${pageNum}`);
        break;
      }
    } else {
      staleCount = 0;
    }
    prevScreenshotSize = ssSize;
    prevScreenshotHash = ssHash;

    log(`Page ${padPage(pageNum)}: screenshot saved (${(ssSize / 1024).toFixed(0)} KB)`);

    // Turn to next page
    const turned = await turnPage(viewerPage);
    if (!turned) {
      log('Could not turn page. Reached the end.');
      break;
    }

    await sleep(2000);
  }

  if (pageNum >= opts.maxPages) {
    log(`Reached max-pages limit (${opts.maxPages}). Use --max-pages to increase.`);
  }

  return { pageNum, totalChars: 0, outDir };
}

// ---------------------------------------------------------------------------
// Text extraction strategies
// ---------------------------------------------------------------------------
async function extractPageText(page, detectedSelector, viewerType) {
  // Strategy 1: Direct innerText from detected viewer container
  if (detectedSelector && viewerType === 'dom') {
    try {
      const text = await page.$eval(detectedSelector, (el) => el.innerText);
      if (text && text.trim().length > 10) {
        return cleanText(text);
      }
    } catch {
      // Selector gone or inaccessible
    }
  }

  // Strategy 2: iframe content extraction (HONTO viewer may use iframes)
  try {
    const frames = page.frames();
    for (const frame of frames) {
      if (frame === page.mainFrame()) continue;
      try {
        const text = await frame.evaluate(() => {
          // Try multiple content selectors within the iframe
          const selectors = [
            '#content_p',
            '#content',
            '.content',
            '.page-content',
            '.text-content',
            'body',
          ];
          for (const sel of selectors) {
            const el = document.querySelector(sel);
            if (el) {
              const t = el.innerText;
              if (t && t.trim().length > 10) return t;
            }
          }
          return document.body?.innerText || '';
        });
        if (text && text.trim().length > 10) {
          return cleanText(text);
        }
      } catch {
        // Frame not accessible (cross-origin)
      }
    }
  } catch {
    // No iframes
  }

  // Strategy 3: Collect visible span/p/div text elements within reader area
  try {
    const text = await page.evaluate(() => {
      // BinB reader and common EPUB viewer containers
      const containerCandidates = document.querySelectorAll(
        '#content_p, #content, #binb, [class*="reader"], [class*="viewer"], ' +
        '[class*="content"], [class*="page"], [id*="reader"], [id*="viewer"], ' +
        '[id*="content"], [id*="page"], .epub-container, #epub-viewer'
      );

      // Pick the container with the most text content
      let bestContainer = null;
      let bestLength = 0;
      for (const container of containerCandidates) {
        const t = container.innerText?.trim() || '';
        if (t.length > bestLength) {
          bestLength = t.length;
          bestContainer = container;
        }
      }

      if (!bestContainer || bestLength < 10) return '';

      // Extract text from child elements to avoid duplicates
      const els = bestContainer.querySelectorAll('span, p, div, h1, h2, h3, h4, h5, h6, section, article');
      const results = [];
      for (const el of els) {
        // Skip elements that have child elements with text (avoid double-counting)
        if (el.children.length > 0) {
          const hasTextChild = Array.from(el.children).some(
            (c) => c.innerText?.trim().length > 0
          );
          if (hasTextChild) continue;
        }
        const t = el.innerText?.trim();
        if (t && t.length > 0) {
          results.push(t);
        }
      }

      // If leaf-node extraction gave nothing, fall back to container innerText
      if (results.length === 0) {
        return bestContainer.innerText || '';
      }

      // Deduplicate adjacent identical strings
      const deduped = [];
      for (const r of results) {
        if (deduped.length === 0 || deduped[deduped.length - 1] !== r) {
          deduped.push(r);
        }
      }
      return deduped.join('\n');
    });

    if (text && text.trim().length > 10) {
      return cleanText(text);
    }
  } catch {
    // Failed
  }

  // Strategy 4: Fall back to all visible text excluding nav/toolbar
  try {
    const text = await page.evaluate(() => {
      const exclude = new Set();
      document
        .querySelectorAll(
          'nav, header, footer, [role="navigation"], [role="toolbar"], ' +
          '[role="menu"], [role="menubar"], .toolbar, .nav, .header, .footer, ' +
          '#menu, .menu, [class*="toolbar"], [class*="menu"], [class*="nav"]'
        )
        .forEach((el) => exclude.add(el));

      function walk(node) {
        if (exclude.has(node)) return '';
        if (node.nodeType === 3) return node.textContent || '';
        if (node.nodeType !== 1) return '';
        const style = window.getComputedStyle(node);
        if (style.display === 'none' || style.visibility === 'hidden') return '';
        if (parseFloat(style.opacity) === 0) return '';
        let text = '';
        for (const child of node.childNodes) {
          text += walk(child);
        }
        return text;
      }

      return walk(document.body);
    });

    if (text && text.trim().length > 20) {
      return cleanText(text);
    }
  } catch {
    // Failed
  }

  // All strategies failed
  return null;
}

// ---------------------------------------------------------------------------
// Clean extracted text
// ---------------------------------------------------------------------------
function cleanText(raw) {
  if (!raw) return raw;

  // Remove common UI/navigation/settings artifacts from HONTO BinB viewer
  const uiPatterns = [
    /^(目次|もくじ|Table of Contents)$/gm,
    /^\d+\s*\/\s*\d+$/gm, // Page numbers like "3 / 120"
    /^(前のページ|次のページ|前へ|次へ)$/gm,
    /^(設定|しおり|ブックマーク|メニュー)$/gm,
    /^文字サイズ$/gm,
    /^行間$/gm,
    /^(標準|広い)$/gm,
    /^余白$/gm,
    /^(小|中|大)$/gm,
    /^書体$/gm,
    /^(既定|ゴシック体|明朝体)$/gm,
    /^ルビ$/gm,
    /^(表示|非表示)$/gm,
    /^テーマ$/gm,
    /^(ライト|ダーク|セピア)$/gm,
    /^確定$/gm,
    /^初期設定に戻す$/gm,
    /^T$/gm,
  ];

  let cleaned = raw;
  for (const pat of uiPatterns) {
    cleaned = cleaned.replace(pat, '');
  }

  // Collapse multiple blank lines
  cleaned = cleaned.replace(/\n{3,}/g, '\n\n');

  return cleaned.trim();
}

// ---------------------------------------------------------------------------
// Page turning
// ---------------------------------------------------------------------------
async function turnPage(page) {
  // BinB reader for Japanese vertical books: ArrowLeft = next page
  // Method 1: ArrowLeft key (most reliable for BinB)
  try {
    await page.keyboard.press('ArrowLeft');
    return true;
  } catch {
    // Keyboard not available
  }

  // Method 2: Click the left 10% of the viewport
  try {
    const viewport = page.viewportSize();
    if (viewport) {
      await page.mouse.click(viewport.width * 0.05, viewport.height * 0.5);
      return true;
    }
  } catch {
    // Failed
  }

  // Method 3: Look for next-page navigation buttons
  const navSelectors = [
    'a:has-text("次")',
    'button:has-text("次")',
    '[class*="next"]',
    '[class*="forward"]',
    '#next',
    '.next-page',
    '[aria-label="next"]',
    '[aria-label="次のページ"]',
    // BinB reader navigation
    '#binb-left',
    '.pager-left',
  ];

  for (const sel of navSelectors) {
    try {
      const btn = await page.$(sel);
      if (btn) {
        const visible = await btn.isVisible();
        if (visible) {
          await btn.click();
          return true;
        }
      }
    } catch {
      // Try next
    }
  }

  // Method 4: ArrowRight as fallback (some viewers use this regardless of reading direction)
  try {
    await page.keyboard.press('ArrowRight');
    return true;
  } catch {
    // Failed
  }

  return false;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
async function main() {
  const opts = parseArgs();

  log('=== honto-extract ===');
  log(`  slug: ${opts.slug}`);
  log(`  max-pages: ${opts.maxPages}`);
  if (opts.bookUrl) log(`  book-url: ${opts.bookUrl}`);
  if (opts.readerOnly) log(`  mode: reader-only`);
  log(`  profile: ${USER_DATA_DIR}`);
  log(`  output: /tmp/kindle-translate/${opts.slug}/raw/`);
  log('');

  ensureDir(USER_DATA_DIR);

  const context = await chromium.launchPersistentContext(USER_DATA_DIR, {
    headless: false,
    viewport: { width: 1280, height: 900 },
    locale: 'ja-JP',
    args: [
      '--disable-blink-features=AutomationControlled',
    ],
  });

  const page = context.pages()[0] || (await context.newPage());

  try {
    // Step 1: Navigate to book and open viewer
    await openBookInViewer(page, opts);

    // Step 2: Extract text from viewer
    const result = await extractFromViewer(page, opts);

    // Step 3: Summary
    log('');
    log('=== Extraction Complete ===');
    log(`  Pages extracted: ${result.pageNum}`);
    log(`  Total characters: ${result.totalChars}`);
    log(`  Output directory: ${result.outDir}`);
    log('');
    log('Next step: run the translation pipeline:');
    log(
      `  bash ~/Documents/life-os/skills/kindle-translate/kindle-translate-pipeline.sh ${opts.slug}`
    );
  } catch (err) {
    log(`ERROR: ${err.message}`);
    const ssPath = '/tmp/honto-extract-error.png';
    await page.screenshot({ path: ssPath }).catch(() => {});
    log(`Screenshot saved to ${ssPath}`);
    process.exit(1);
  } finally {
    // Close all pages including any viewer tabs
    await context.close();
  }
}

main();
