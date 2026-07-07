/**
 * browser-relay-threads.mjs — capture skill 的 Browser Relay 真實實作
 *
 * 背景：capture skill 文件裡長年寫著「curl → web_fetch → Browser Relay」三層
 *       fallback，但 Browser Relay 從 2026-03-24 起只是文件裡的策略名稱，從未
 *       真正實作過（2026-06-25 盤查確認：repo 裡沒有任何對應程式碼）。這支就是
 *       補上這個坑的第一個真實實作，專門處理 Threads。
 *
 * 觸發情境（curl-based 擷取在這兩種情況會失敗，此時呼叫本程式）：
 *   1. 登入牆：og:title 回傳「Threads • Log in」（私人帳號或內容限制）
 *   2. 多段接龍/留言：curl 只拿到首篇貼文，留言跟接龍段落是 client-side
 *      GraphQL 動態載入，純 HTTP 永遠抓不到
 *
 * 機制：用已登入的瀏覽器（~/chrome-autobot persistent profile，與
 *       ws/ecommerce/ 電商比價腳本共用同一個 profile 但是獨立檔案，避免
 *       兩邊並行開發互相衝突）開頁面、往下滑動觸發留言載入，
 *       再抓 DOM 文字 + 全頁截圖，交給 Claude 視覺/文字雙重讀取。
 *
 * 前置：~/chrome-autobot profile 需登入 Instagram（Threads 共用 IG 帳號）。
 *
 * Usage: node browser-relay-threads.mjs "<threads post url>" [--json]
 */

import { chromium } from '/opt/homebrew/lib/node_modules/playwright/index.mjs';
import { mkdir } from 'node:fs/promises';

const USER_DATA_DIR = `${process.env.HOME}/chrome-autobot`;
const HEADLESS = process.env.HEADLESS === '1';
const SCREENSHOT_DIR = process.env.SOCIAL_SHOT_DIR || '/tmp/browser-social';

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function ensureShotDir() {
  await mkdir(SCREENSHOT_DIR, { recursive: true });
}

function shotPath(label) {
  const ts = new Date().toISOString().replace(/[:.]/g, '-');
  return `${SCREENSHOT_DIR}/threads-${label}-${ts}.png`;
}

async function readThreadsPost(url, options = {}) {
  const { maxScrolls = 8 } = options;

  let ctx;
  try {
    ctx = await chromium.launchPersistentContext(USER_DATA_DIR, {
      channel: 'chrome',
      headless: HEADLESS,
      viewport: null,
      args: ['--no-first-run', '--no-default-browser-check'],
    });
    console.error('✅ Chrome launched (persistent profile, headless=' + HEADLESS + ')');

    const page = await ctx.newPage();
    await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 30000 });
    await sleep(2000);

    // 偵測是否被導去登入頁（未登入態）
    const isLoginWall = await page.locator('text=登入 Instagram, text=Log in to Instagram').count().catch(() => 0);
    if (isLoginWall > 0) {
      await ensureShotDir();
      const path = shotPath('loginwall');
      await page.screenshot({ path, type: 'png' });
      return { url, blocked: 'login_required', screenshotPath: path };
    }

    // 往下滑動觸發留言動態載入（GraphQL lazy-load）
    let lastHeight = 0;
    for (let i = 0; i < maxScrolls; i++) {
      const height = await page.evaluate(() => document.body.scrollHeight);
      if (height === lastHeight && i > 1) break; // 沒有新內容載入了
      lastHeight = height;
      await page.mouse.wheel(0, 1800);
      await sleep(1200 + Math.floor(Math.random() * 800));
    }

    // 嘗試抓可見文字節點作為留言內容（best-effort，Threads DOM 結構可能變動）
    let replies = [];
    try {
      replies = await page.$$eval('div[role="button"] span, div span[dir="auto"]', els =>
        els
          .map(el => el.innerText?.trim())
          .filter(t => t && t.length > 5 && t.length < 1000)
      );
      // 去重
      replies = [...new Set(replies)];
    } catch {
      // DOM選擇器可能失效，靠截圖視覺讀取
    }

    await ensureShotDir();
    const path = shotPath('full');
    await page.screenshot({ path, type: 'png', fullPage: true });

    return {
      url,
      blocked: null,
      screenshotPath: path,
      scrollRounds: lastHeight > 0 ? maxScrolls : 0,
      extractedTextNodes: replies,
      note: replies.length
        ? `DOM抓到${replies.length}個文字節點(含貼文本身+留言，未去除雜訊)，截圖供交叉確認`
        : 'DOM文字抓取未命中，僅靠截圖視覺讀取',
    };
  } finally {
    if (ctx) await ctx.close();
  }
}

// ── CLI entry ───────────────────────────────────────────

const url = process.argv[2];
const jsonFlag = process.argv.includes('--json');

if (!url) {
  console.error('Usage: node browser-relay-threads.mjs "<threads post url>" [--json]');
  process.exit(1);
}

readThreadsPost(url)
  .then(result => {
    if (jsonFlag) {
      console.log(JSON.stringify(result, null, 2));
    } else if (result.blocked) {
      console.log(`⚠️ 被導去登入頁，未登入態。截圖：${result.screenshotPath}`);
    } else {
      console.log(`📸 截圖（含留言滾動載入後）：${result.screenshotPath}`);
      console.log(`📝 DOM文字節點：${result.extractedTextNodes.length} 個`);
      console.log(result.note);
    }
    process.exit(0);
  })
  .catch(e => {
    console.error('Fatal:', e.message);
    process.exit(1);
  });
