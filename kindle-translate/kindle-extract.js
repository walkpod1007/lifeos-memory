#!/usr/bin/env node
// kindle-extract.js — Extract text from Kindle Cloud Reader via Playwright
//
// Usage:
//   node kindle-extract.js --search "書名" --slug my-book
//   node kindle-extract.js --url "https://www.amazon.co.jp/dp/XXXXXXXXXX" --slug my-book
//   node kindle-extract.js --slug my-book --reader-only   # skip purchase, go straight to reader
//
// Flags:
//   --search <title>   Search Amazon.co.jp for this book title
//   --url <url>        Direct Amazon.co.jp product URL
//   --slug <name>      Output directory name (required)
//   --max-pages <n>    Safety limit (default 50)
//   --reader-only      Skip Amazon search/purchase, go straight to Kindle Cloud Reader

const fs = require('fs');
const path = require('path');
const readline = require('readline');

// Resolve playwright: try local node_modules first, then global
let playwright;
try {
  playwright = require('playwright');
} catch {
  // Fallback to global npm install path
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
      case '--search':
        opts.search = args[++i];
        break;
      case '--url':
        opts.url = args[++i];
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
      default:
        console.error(`Unknown flag: ${args[i]}`);
        process.exit(1);
    }
  }

  if (!opts.slug) {
    console.error('ERROR: --slug is required');
    console.error('Usage: node kindle-extract.js --search "書名" --slug my-book');
    console.error('       node kindle-extract.js --url "https://..." --slug my-book');
    console.error('       node kindle-extract.js --slug my-book --reader-only');
    process.exit(1);
  }
  if (!opts.search && !opts.url && !opts.readerOnly) {
    console.error('ERROR: one of --search, --url, or --reader-only is required');
    process.exit(1);
  }
  return opts;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
const USER_DATA_DIR = '/tmp/kindle-playwright-profile';

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
  // Check for Amazon login page indicators
  const loginSelectors = [
    '#ap_email',
    '#ap_password',
    'input[name="email"]',
    'form[name="signIn"]',
  ];

  for (const sel of loginSelectors) {
    const el = await page.$(sel);
    if (el) {
      log('Login page detected.');
      await promptUser(
        'Please log in to Amazon.co.jp in the browser window, then press Enter in terminal...'
      );
      // Wait a moment for page to settle after login
      await sleep(2000);
      return true;
    }
  }
  return false;
}

// ---------------------------------------------------------------------------
// Step 1: Search & get free sample
// ---------------------------------------------------------------------------
async function searchAndGetSample(page, opts) {
  if (opts.url) {
    log(`Navigating to product URL: ${opts.url}`);
    await page.goto(opts.url, { waitUntil: 'domcontentloaded', timeout: 30000 });
  } else {
    log(`Searching Amazon.co.jp for: "${opts.search}"`);
    await page.goto('https://www.amazon.co.jp', {
      waitUntil: 'domcontentloaded',
      timeout: 30000,
    });

    await handleLoginIfNeeded(page);

    // Type in search box
    const searchBox = await page.waitForSelector('#twotabsearchtextbox', { timeout: 15000 });
    await searchBox.fill(opts.search);
    await searchBox.press('Enter');
    log('Search submitted, waiting for results...');

    await page.waitForLoadState('domcontentloaded', { timeout: 30000 });

    // Click first result that looks like a Kindle book
    // Amazon search results: look for Kindle edition links
    const resultSelectors = [
      // Data component result links
      'div[data-component-type="s-search-result"] h2 a',
      // Fallback: any search result link
      '.s-result-item h2 a',
      '.s-search-results h2 a',
    ];

    let clicked = false;
    for (const sel of resultSelectors) {
      const link = await page.$(sel);
      if (link) {
        const title = await link.innerText();
        log(`Clicking first result: "${title.substring(0, 60)}..."`);
        await link.click();
        clicked = true;
        break;
      }
    }

    if (!clicked) {
      log('WARNING: Could not find search results. Taking screenshot.');
      await page.screenshot({ path: '/tmp/kindle-extract-search-fail.png' });
      throw new Error('No search results found. Screenshot saved to /tmp/kindle-extract-search-fail.png');
    }

    await page.waitForLoadState('domcontentloaded', { timeout: 30000 });
  }

  await handleLoginIfNeeded(page);

  log('On product page. Looking for free sample / trial read button...');

  // Try to get free sample or trial read
  const sampleSelectors = [
    // "無料サンプルを送信" button
    '#sendSampleButton',
    'input[name="submit.send-sample"]',
    'a:has-text("無料サンプルを送信")',
    'span:has-text("無料サンプルを送信")',
    // "試し読み" (trial read) button — opens Cloud Reader directly
    'a:has-text("試し読み")',
    'a[href*="read.amazon.co.jp"]',
    '#sitbReaderOpener',
    // Kindle edition selection first
    'a:has-text("Kindle版")',
    // "今すぐ無料で読む" for Kindle Unlimited
    'a:has-text("今すぐ無料で読む")',
  ];

  let sampleSent = false;
  for (const sel of sampleSelectors) {
    try {
      const btn = await page.$(sel);
      if (btn) {
        const btnText = await btn.innerText().catch(() => sel);
        log(`Found button: "${btnText}" — clicking...`);

        // If it's a "試し読み" link that opens Cloud Reader, note it
        const href = await btn.getAttribute('href').catch(() => '');
        if (href && href.includes('read.amazon.co.jp')) {
          log('This opens Cloud Reader directly — will navigate there.');
        }

        await btn.click();
        await sleep(3000);
        sampleSent = true;
        break;
      }
    } catch {
      // Selector didn't match, try next
    }
  }

  if (!sampleSent) {
    log('WARNING: Could not find sample/trial button. The book may already be in your library.');
    log('Taking screenshot for reference...');
    await page.screenshot({ path: '/tmp/kindle-extract-product-page.png' });
    log('Screenshot saved to /tmp/kindle-extract-product-page.png');
    log('Proceeding to Kindle Cloud Reader to check library...');
  } else {
    log('Sample request sent (or trial read opened). Waiting for confirmation...');
    await sleep(3000);
  }
}

// ---------------------------------------------------------------------------
// Step 2: Extract from Kindle Cloud Reader
// ---------------------------------------------------------------------------
async function extractFromReader(page, opts) {
  const outDir = `/tmp/kindle-translate/${opts.slug}/raw`;
  ensureDir(outDir);

  // Extract ASIN from URL if available (e.g., /dp/B0DWMMDV94)
  let asin = null;
  if (opts.url) {
    const m = opts.url.match(/\/(?:dp|gp\/product|ASIN)\/(B[A-Z0-9]{9})/i);
    if (m) asin = m[1];
  }

  if (asin) {
    // Direct read URL — skip library entirely
    const readUrl = `https://read.amazon.co.jp/?asin=${asin}`;
    log(`Opening book directly: ${readUrl}`);
    await page.goto(readUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });
    await handleLoginIfNeeded(page);
    log('Waiting for reader to load...');
    await sleep(8000);
  } else {
    log('Navigating to Kindle Cloud Reader library...');
    await page.goto('https://read.amazon.co.jp/', {
      waitUntil: 'domcontentloaded',
      timeout: 30000,
    });
    await handleLoginIfNeeded(page);
    log('Waiting for library to load...');
    await sleep(5000);

  // Wait for the library grid/list to appear
  const librarySelectors = [
    '#library',
    '.library-list',
    '#kindle-library-list',
    'div[id*="library"]',
    'div[class*="library"]',
    'img[src*="images-na.ssl-images-amazon.com"]', // Book cover images
  ];

  let libraryLoaded = false;
  for (const sel of librarySelectors) {
    try {
      await page.waitForSelector(sel, { timeout: 15000 });
      libraryLoaded = true;
      log(`Library loaded (matched: ${sel})`);
      break;
    } catch {
      // Try next selector
    }
  }

  if (!libraryLoaded) {
    log('WARNING: Library container not detected via known selectors.');
    log('Taking screenshot. You may need to manually navigate to the book.');
    await page.screenshot({ path: '/tmp/kindle-extract-library.png' });
    await promptUser('Navigate to the book in Cloud Reader, then press Enter...');
  }

  // Try to find and click the book
  // Kindle Cloud Reader shows books as clickable covers or list items
  if (opts.search) {
    log(`Looking for book matching: "${opts.search}"...`);
    const searchShort = opts.search.substring(0, 10);
    let bookClicked = false;

    // Strategy 1: find any element whose text includes part of the title
    try {
      const el = await page.locator(`text=${searchShort}`).first();
      if (await el.isVisible({ timeout: 3000 })) {
        log(`Found by partial text "${searchShort}", clicking...`);
        await el.click();
        bookClicked = true;
      }
    } catch { /* try next */ }

    // Strategy 2: img with alt containing title
    if (!bookClicked) {
      try {
        const img = await page.locator(`img[alt*="${searchShort}"]`).first();
        if (await img.isVisible({ timeout: 2000 })) {
          log(`Found by img alt "${searchShort}", clicking...`);
          await img.click();
          bookClicked = true;
        }
      } catch { /* try next */ }
    }

    // Strategy 3: title attribute
    if (!bookClicked) {
      try {
        const titled = await page.locator(`[title*="${searchShort}"]`).first();
        if (await titled.isVisible({ timeout: 2000 })) {
          log(`Found by title attr "${searchShort}", clicking...`);
          await titled.click();
          bookClicked = true;
        }
      } catch { /* try next */ }
    }

    // Strategy 4: ASIN-based element IDs or first book in grid
    if (!bookClicked) {
      for (const sel of ['li[id^="B"]', 'div[id^="B"]', '.book_container:first-child']) {
        try {
          const el = await page.$(sel);
          if (el) {
            log(`Found by selector "${sel}", clicking...`);
            await el.click();
            bookClicked = true;
            break;
          }
        } catch { /* try next */ }
      }
    }

    if (!bookClicked) {
      log('Could not auto-detect the book. Taking screenshot.');
      await page.screenshot({ path: '/tmp/kindle-extract-library-books.png' });
      await promptUser(
        'Please click on the book in the Cloud Reader window, then press Enter...'
      );
    }
  } else {
    log('No search term provided. Please select the book in the reader.');
    await page.screenshot({ path: '/tmp/kindle-extract-library-books.png' });
    await promptUser('Click on the book in the Cloud Reader window, then press Enter...');
  }

  log('Waiting for reader to load...');
  await sleep(5000);

  // Verify we left the library — check URL or DOM changed
  const afterUrl = page.url();
  if (afterUrl.includes('/library') || afterUrl === 'https://read.amazon.co.jp/') {
    log('WARNING: Still on library page after click. Taking screenshot.');
    await page.screenshot({ path: '/tmp/kindle-extract-still-library.png' });
    // Try double-clicking the first visible book cover
    try {
      const firstCover = await page.locator('img').first();
      if (await firstCover.isVisible({ timeout: 2000 })) {
        log('Attempting double-click on first visible image...');
        await firstCover.dblclick();
        await sleep(5000);
      }
    } catch { /* give up */ }
  }
  } // end of non-ASIN library path

  // Wait for reader content area
  const readerSelectors = [
    '#kindleReader_content',
    '#kindleReader',
    '#kr-renderer',
    'iframe#KindleReaderIFrame',
    'div[id*="reader"]',
    'div[class*="reader"]',
    'canvas',                // Canvas-based renderer
  ];

  let readerContainer = null;
  let readerType = 'unknown';

  for (const sel of readerSelectors) {
    try {
      const el = await page.waitForSelector(sel, { timeout: 10000 });
      if (el) {
        readerContainer = sel;
        readerType = sel.includes('canvas') ? 'canvas' : 'dom';
        log(`Reader loaded (${readerType}): ${sel}`);
        break;
      }
    } catch {
      // Try next
    }
  }

  if (!readerContainer) {
    log('WARNING: Reader container not detected. Taking screenshot.');
    await page.screenshot({ path: '/tmp/kindle-extract-reader-fail.png' });
    await promptUser(
      'Make sure the book is open in the reader, then press Enter...'
    );
  }

  // ---------------------------------------------------------------------------
  // Page extraction loop
  // ---------------------------------------------------------------------------
  log(`Starting extraction (max ${opts.maxPages} pages)...`);

  let pageNum = 0;
  let totalChars = 0;
  let previousText = '';
  let staleCount = 0;
  const MAX_STALE = 3; // If text unchanged for 3 consecutive turns, assume end

  while (pageNum < opts.maxPages) {
    pageNum++;

    const text = await extractPageText(page, readerContainer);

    if (!text || text.trim().length === 0) {
      log(`Page ${padPage(pageNum)}: [empty — possibly canvas-rendered]`);

      // Take screenshot for canvas-rendered pages
      const ssPath = path.join(outDir, `page-${padPage(pageNum)}-canvas.png`);
      await page.screenshot({ path: ssPath, fullPage: false });

      const notePath = path.join(outDir, `page-${padPage(pageNum)}.txt`);
      fs.writeFileSync(notePath, '[canvas-rendered — see screenshot]\n');

      // Still try to turn the page
      const turned = await turnPage(page);
      if (!turned) {
        log('Could not turn page. Reached the end or reader stalled.');
        break;
      }
      await sleep(1500);
      continue;
    }

    // Check for duplicate / end of book
    const trimmed = text.trim();
    if (trimmed === previousText.trim()) {
      staleCount++;
      log(`Page ${padPage(pageNum)}: [duplicate text, stale count: ${staleCount}/${MAX_STALE}]`);
      if (staleCount >= MAX_STALE) {
        log('Text unchanged after multiple page turns — end of book detected.');
        pageNum--; // Don't count the duplicate
        break;
      }
    } else {
      staleCount = 0;
    }

    // Save the page
    const pagePath = path.join(outDir, `page-${padPage(pageNum)}.txt`);
    fs.writeFileSync(pagePath, trimmed + '\n');
    totalChars += trimmed.length;
    previousText = trimmed;

    const preview = trimmed.substring(0, 50).replace(/\n/g, ' ');
    log(`Page ${padPage(pageNum)}: ${trimmed.length} chars — "${preview}..."`);

    // Turn to next page
    const turned = await turnPage(page);
    if (!turned) {
      log('Could not turn page. Reached the end.');
      break;
    }

    // Wait for page render
    await sleep(1500);
  }

  if (pageNum >= opts.maxPages) {
    log(`Reached max-pages limit (${opts.maxPages}). Use --max-pages to increase.`);
  }

  return { pageNum, totalChars, outDir };
}

// ---------------------------------------------------------------------------
// Text extraction strategies
// ---------------------------------------------------------------------------
async function extractPageText(page, readerSelector) {
  // Strategy 1: Direct innerText from reader content container
  const strategy1Selectors = [
    '#kindleReader_content',
    '#kr-renderer',
    '#kindleReader',
    'div[id*="reader-content"]',
  ];

  for (const sel of strategy1Selectors) {
    try {
      const text = await page.$eval(sel, (el) => el.innerText);
      if (text && text.trim().length > 10) {
        return text;
      }
    } catch {
      // Selector not found, try next
    }
  }

  // Strategy 2: Look for iframe and extract from its content
  try {
    const frames = page.frames();
    for (const frame of frames) {
      if (frame === page.mainFrame()) continue;
      try {
        const text = await frame.evaluate(() => document.body?.innerText || '');
        if (text && text.trim().length > 10) {
          return text;
        }
      } catch {
        // Frame not accessible
      }
    }
  } catch {
    // No iframes or not accessible
  }

  // Strategy 3: Collect all visible span/p elements in reader area
  try {
    const text = await page.evaluate(() => {
      // Find the main reader area
      const containers = document.querySelectorAll(
        '#kindleReader_content, #kr-renderer, #kindleReader, [id*="reader"], [class*="reader"]'
      );
      const results = [];
      for (const container of containers) {
        const els = container.querySelectorAll('span, p, div.a-text-normal');
        for (const el of els) {
          const t = el.innerText?.trim();
          if (t && t.length > 1) {
            results.push(t);
          }
        }
      }
      // Deduplicate adjacent identical strings (nested elements repeat text)
      const deduped = [];
      for (const r of results) {
        if (deduped.length === 0 || deduped[deduped.length - 1] !== r) {
          deduped.push(r);
        }
      }
      return deduped.join('\n');
    });

    if (text && text.trim().length > 10) {
      return text;
    }
  } catch {
    // Failed
  }

  // Strategy 4: All visible text on page (last resort, noisy)
  try {
    const text = await page.evaluate(() => {
      // Exclude navigation, toolbars, etc.
      const exclude = new Set();
      document
        .querySelectorAll('nav, header, footer, [role="navigation"], [role="toolbar"]')
        .forEach((el) => exclude.add(el));

      function walk(node) {
        if (exclude.has(node)) return '';
        if (node.nodeType === 3) return node.textContent || '';
        if (node.nodeType !== 1) return '';
        const style = window.getComputedStyle(node);
        if (style.display === 'none' || style.visibility === 'hidden') return '';
        let text = '';
        for (const child of node.childNodes) {
          text += walk(child);
        }
        return text;
      }

      return walk(document.body);
    });

    if (text && text.trim().length > 20) {
      return text;
    }
  } catch {
    // Failed
  }

  // All strategies failed
  return null;
}

// ---------------------------------------------------------------------------
// Page turning
// ---------------------------------------------------------------------------
async function turnPage(page) {
  // Method 1: Press right arrow key (most common for Kindle Cloud Reader)
  try {
    await page.keyboard.press('ArrowRight');
    return true;
  } catch {
    // Keyboard not available
  }

  // Method 2: Click the right-side navigation area
  const navSelectors = [
    '#kindleReader_pageTurnAreaRight',
    '.pageRight',
    '[class*="right"]',
    '#kr-next-page',
  ];

  for (const sel of navSelectors) {
    try {
      const btn = await page.$(sel);
      if (btn) {
        await btn.click();
        return true;
      }
    } catch {
      // Try next
    }
  }

  // Method 3: Click the right 20% of the viewport
  try {
    const viewport = page.viewportSize();
    if (viewport) {
      await page.mouse.click(viewport.width * 0.9, viewport.height * 0.5);
      return true;
    }
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

  log('=== kindle-extract ===');
  log(`  slug: ${opts.slug}`);
  log(`  max-pages: ${opts.maxPages}`);
  if (opts.search) log(`  search: "${opts.search}"`);
  if (opts.url) log(`  url: ${opts.url}`);
  if (opts.readerOnly) log(`  mode: reader-only`);
  log(`  profile: ${USER_DATA_DIR}`);
  log('');

  ensureDir(USER_DATA_DIR);

  const context = await chromium.launchPersistentContext(USER_DATA_DIR, {
    headless: false,
    viewport: { width: 1280, height: 900 },
    locale: 'ja-JP',
    args: [
      '--disable-blink-features=AutomationControlled', // reduce bot detection
    ],
  });

  const page = context.pages()[0] || (await context.newPage());

  try {
    // Step 1: Search & get sample (unless reader-only mode)
    if (!opts.readerOnly) {
      await searchAndGetSample(page, opts);
    }

    // Step 2: Extract from Cloud Reader
    const result = await extractFromReader(page, opts);

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
    const ssPath = '/tmp/kindle-extract-error.png';
    await page.screenshot({ path: ssPath }).catch(() => {});
    log(`Screenshot saved to ${ssPath}`);
    process.exit(1);
  } finally {
    await context.close();
  }
}

main();
