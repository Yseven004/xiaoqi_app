from __future__ import annotations

import os
import sys
import http.cookiejar
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


token_path = Path(os.environ.get("XIAOQI_DSH_WEB_TOKEN_FILE", "/opt/xiaoqi-dsh/web-launch-token"))
try:
    token = token_path.read_text(encoding="utf-8").strip()
    if not token:
        raise RuntimeError("launch credential is empty")
    url = "http://127.0.0.1:8091/?" + urllib.parse.urlencode({"token": token})
    # DSH exchanges the launch token for a signed HttpOnly cookie and then
    # redirects to the clean URL. Keep that cookie just as a browser does.
    cookies = http.cookiejar.CookieJar()
    browser = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cookies))
    with browser.open(url, timeout=4) as response:
        response.read(128)
except urllib.error.HTTPError as error:
    print(f"official Web returned HTTP {error.code}", file=sys.stderr)
    raise SystemExit(1) from None
except Exception as error:
    print(f"official Web health failed: {type(error).__name__}", file=sys.stderr)
    raise SystemExit(1) from None
