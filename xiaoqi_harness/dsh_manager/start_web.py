from __future__ import annotations

import os
import re
import signal
import subprocess
import sys
import urllib.parse
from pathlib import Path


TOKEN_PATH = Path(os.environ.get("XIAOQI_DSH_WEB_TOKEN_FILE", "/opt/xiaoqi-dsh/web-launch-token"))
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
TOKEN_QUERY = re.compile(r"([?&]token=)[^&\s]+", re.IGNORECASE)


def _save_token(url: str) -> bool:
    query = urllib.parse.parse_qs(urllib.parse.urlsplit(url).query)
    token = query.get("token", [""])[0]
    if not token or len(token) > 2048 or any(character.isspace() for character in token):
        return False
    TOKEN_PATH.parent.mkdir(parents=True, exist_ok=True)
    temporary = TOKEN_PATH.with_name(TOKEN_PATH.name + ".tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as output:
        output.write(token)
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary, TOKEN_PATH)
    os.chmod(TOKEN_PATH, 0o600)
    return True


def main() -> int:
    TOKEN_PATH.unlink(missing_ok=True)
    admin_host = os.environ.get("XIAOQI_ADMIN_HOST", "").strip()
    if not admin_host:
        print("[dsh-web] XIAOQI_ADMIN_HOST is required", flush=True)
        return 2
    command = [
        os.environ.get("DSH_BIN", "dsh"),
        "--profile", "web",
        "--no-open",
        "--host", "127.0.0.1",
        "--port", os.environ.get("XIAOQI_DSH_WEB_PORT", "8091"),
        "--trusted-host", admin_host,
    ]
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)

    def stop(signum: int, _frame: object) -> None:
        if process.poll() is None:
            process.send_signal(signum)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    token_saved = False
    try:
        assert process.stdout is not None
        for original in process.stdout:
            clean = ANSI.sub("", original).rstrip("\r\n")
            if clean.startswith("dsh web:"):
                url = clean.partition(":")[2].strip()
                token_saved = _save_token(url)
                print("[dsh-web] official Web launch credential captured" if token_saved else "[dsh-web] launch credential was not present", flush=True)
                continue
            print(TOKEN_QUERY.sub(r"\1[redacted]", clean), flush=True)
        return_code = process.wait()
        return return_code
    finally:
        TOKEN_PATH.unlink(missing_ok=True)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"[dsh-web] startup failed: {type(error).__name__}: {error}", file=sys.stderr, flush=True)
        raise SystemExit(1)
