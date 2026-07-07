---
name: clone-website
description: >
  逆向重建整個網站成可跑的 Next.js 專案：瀏覽器偵察→抽設計 token→寫元件規格→
  多 agent worktree 並行蓋→視覺比對 QA，產出可維護的原始碼而非截圖式複製。
  觸發：克隆這個網站、複製這個站、rebuild this page、pixel-perfect clone、照這個站做一個。
  不觸發：只要設計 token 文件（design-extract）、從零做單頁 HTML（frontend）、抓網頁內容存檔（capture）。
  消歧：要「可跑的網站成品」→本 skill；只要「風格分析文件 DESIGN.md」→design-extract。
version: "1.0"
created: "2026-07-06"
---

# Clone Website — 網站逆向重建

把目標網站重建成 Next.js 16 + shadcn/ui + Tailwind v4 專案。完整五階段 playbook
見 `references/clone-website-playbook.md`（473 行，執行時整份讀進來照走）。

## 前置需求（缺一不可）

1. **瀏覽器自動化 MCP**：Chrome MCP / Playwright MCP 擇一可用
2. **模板 scaffold**：先 clone 模板 repo 到工作目錄再開工——
   ```bash
   git clone --depth 1 https://github.com/JCodesMore/ai-website-cloner-template <workdir>
   cd <workdir> && npm install && npm run build   # 驗證 scaffold 可 build
   ```
3. Node.js + npm 可用

## 執行

1. 讀 `references/clone-website-playbook.md` 全文
2. 照 playbook 五階段走：Reconnaissance → Foundation → Component Specs →
   Parallel Build（git worktree 隔離）→ Assembly & QA（視覺 diff）
3. 產出物：可 `npm run build` 通過的完整專案 + `docs/research/` 抽取紀錄

## Life-OS 派工注意

- **很燒額度**：多 builder agent 並行，重案才開；派工前讀 `rules/model-dispatch.md`
- worktree 隔離已內建於 playbook，builder 之間不會互踩
- 目標站資產（圖片/字型）會下載到專案 `public/`——僅限使用者指定的 URL
- 法律面：僅用於參考重建/自有資產/使用者授權場景，不做釣魚仿冒

## Lineage
<!-- 自動聚合至 skills/CAPABILITY-MATRIX.md by gen-capability-matrix.py；勿刪 -->
origin: "github.com/JCodesMore/ai-website-cloner-template v0.3.1 (MIT, 25.8k★), vetted 2026-07-06"
status: active
closeout_gist: ""
