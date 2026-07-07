#!/usr/bin/env python3
"""One-time YouTube OAuth 2.0 setup.
Usage:
  python3 yt_auth.py             # opens browser automatically (local Mac)
  python3 yt_auth.py --url-only  # prints auth URL (for remote/phone auth)

Token saved to ~/.config/yt-sub-translate/token.json
"""
import os
import sys, sys
# yourchannel 帳號同時授予了 yt-analytics scope，Google 會在 token 回傳時夾帶多出的 scope，
# oauthlib 預設把 scope 變動當成 Warning 例外拋出 → fetch_token crash、token 沒存成。
# 這兩個環境變數放寬 scope 比對，必須在 import oauthlib 相關模組「之前」設定。
os.environ.setdefault("OAUTHLIB_RELAX_TOKEN_SCOPE", "1")
os.environ.setdefault("OAUTHLIB_IGNORE_SCOPE_CHANGE", "1")
from google_auth_oauthlib.flow import InstalledAppFlow
from google.oauth2.credentials import Credentials
from google.auth.transport.requests import Request

SCOPES = [
    "https://www.googleapis.com/auth/youtube.force-ssl",
]
CONFIG_DIR = os.path.expanduser("~/.config/yt-sub-translate")
CLIENT_SECRET = os.path.join(CONFIG_DIR, "client_secret.json")
TOKEN_PATH = os.path.join(CONFIG_DIR, "token.json")
# 多帳號：--token-path <path> 指定另存（例：token-yourchannel2.json）
if "--token-path" in sys.argv:
    TOKEN_PATH = os.path.expanduser(sys.argv[sys.argv.index("--token-path") + 1])

def main():
    url_only = "--url-only" in sys.argv
    os.makedirs(CONFIG_DIR, exist_ok=True)

    if not os.path.exists(CLIENT_SECRET):
        print(f"請先下載 OAuth client_secret.json 並放到：{CLIENT_SECRET}")
        print("步驟：")
        print("  1. https://console.cloud.google.com/apis/credentials (帳號: user@example.com)")
        print("  2. 建立「OAuth 2.0 用戶端 ID」→ 桌面應用程式")
        print("  3. 下載 JSON，改名為 client_secret.json")
        return

    creds = None
    if os.path.exists(TOKEN_PATH):
        creds = Credentials.from_authorized_user_file(TOKEN_PATH, SCOPES)

    if not creds or not creds.valid:
        if creds and creds.expired and creds.refresh_token:
            try:
                creds.refresh(Request())
            except Exception as e:
                print(f"Token refresh failed ({e}), starting fresh auth...")
                os.remove(TOKEN_PATH)
                creds = None
        if not creds or not creds.valid:
            flow = InstalledAppFlow.from_client_secrets_file(CLIENT_SECRET, SCOPES)
            if url_only:
                # Headless mode: print URL, user pastes code back
                flow.redirect_uri = "urn:ietf:wg:oauth:2.0:oob"
                auth_url, _ = flow.authorization_url(prompt="consent")
                print("\n請在任意瀏覽器開啟以下連結（用 user@example.com 授權）：")
                print(f"\n{auth_url}\n")
                code = input("授權完成後，貼上頁面顯示的授權碼：").strip()
                flow.fetch_token(code=code)
                creds = flow.credentials
            else:
                creds = flow.run_local_server(port=0)

        with open(TOKEN_PATH, "w") as f:
            f.write(creds.to_json())

    print(f"\n✅ 授權完成，token 存在：{TOKEN_PATH}")
    print(f"   scopes: {creds.scopes}")

if __name__ == "__main__":
    main()
