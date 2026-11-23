"""Run a book-search dataset against a local Genkit/API instance."""

import argparse
import hashlib
import importlib.util
import json
import secrets
import sqlite3
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("book_search_evaluate", HERE / "evaluate.py")
EVAL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EVAL)


class LocalEvaluation(EVAL.Evaluation):
    def __init__(self, root, base_url, contract):
        self.root = str(Path(root).resolve())
        self.base_url = base_url.rstrip("/")
        self.tenant = "book-search-local-" + uuid.uuid4().hex
        self.token = secrets.token_urlsafe(32)
        self.headers = {
            "x-xiaoqi-contract": str(contract),
            "Authorization": "Bearer " + self.token,
            "Content-Type": "application/json",
        }
        device = {
            "tenant_id": self.tenant,
            "device_id": self.tenant,
            "auth_method": "local-evaluation",
            "account_email": self.tenant + "@invalid.local",
            "created_at": int(time.time()),
            "revoked_at": None,
        }
        with self.db() as db:
            db.execute(
                "CREATE TABLE IF NOT EXISTS documents (key TEXT PRIMARY KEY, document TEXT NOT NULL, revision INTEGER NOT NULL)"
            )
            key = "device/" + hashlib.sha256(self.token.encode()).hexdigest()
            db.execute(
                "INSERT OR REPLACE INTO documents VALUES(?,?,1)",
                (key, json.dumps(device)),
            )

    def db(self):
        return sqlite3.connect(self.root + "/xiaoqi.sqlite3", timeout=30)

    def request(self, path, body=None, **headers):
        return urllib.request.Request(
            self.base_url + path,
            headers={**self.headers, **headers},
            data=None if body is None else json.dumps(body).encode(),
        )

    def agent(self, case, search_id, previous):
        try:
            return super().agent(case, search_id, previous)
        except urllib.error.HTTPError as error:
            try:
                payload = json.load(error)
                message = payload.get("message", "") if isinstance(payload, dict) else ""
            except (ValueError, json.JSONDecodeError):
                message = ""
            detail = f":{message[:120]}" if message else ""
            raise ValueError(f"agent_http_{error.code}{detail}") from None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="http://127.0.0.1:8180")
    parser.add_argument("--contract", default="43")
    parser.add_argument("--data-dir", default=str(HERE.parents[2] / ".codex-artifacts" / "genkit-devtools" / "data"))
    parser.add_argument("--output", required=True)
    parser.add_argument("--cases-file", type=Path, default=HERE / "cases.json")
    parser.add_argument("--case-id", action="append")
    args = parser.parse_args()

    dataset = args.cases_file.read_bytes()
    cases = json.loads(dataset)
    if not cases or len({case["id"] for case in cases}) != len(cases):
        raise SystemExit("Case file must contain at least one case and unique IDs")
    if args.case_id:
        selected = set(args.case_id)
        cases = [case for case in cases if case["id"] in selected]
        if len(cases) != len(args.case_id) or len(selected) != len(args.case_id):
            raise SystemExit("Unknown or duplicate --case-id")
        for case in cases:
            if case.get("after") and case["after"] not in selected:
                raise SystemExit(f"Case {case['id']} requires {case['after']}")

    root = Path(args.data_dir).resolve()
    root.mkdir(parents=True, exist_ok=True)
    evaluation = LocalEvaluation(root, args.base_url, args.contract)
    health = None
    for _ in range(60):
        try:
            code, health = evaluation.api("/health")
            if code == 200:
                break
        except OSError:
            pass
        time.sleep(0.5)
    else:
        raise SystemExit("Local Agent API did not become healthy")
    if str(health.get("api_contract_version")) != str(args.contract):
        raise SystemExit("Local Agent API contract does not match the evaluation")

    results = {}
    for case in cases:
        results[case["id"]] = evaluation.run(case, results)
        row = results[case["id"]]
        print(f"{row['id']} {'PASS' if row['pass'] else row.get('reason', 'FAIL')} ({row['ms']} ms)", flush=True)

    release = {
        "target": "local working tree",
        "release_id": health["release_id"],
        "api_contract": args.contract,
    }
    try:
        import subprocess
        release["commit"] = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=HERE.parents[2], text=True
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        release["commit"] = "unknown"

    report = {
        "release": release,
        "health": health,
        "environment": "local synthetic tenant; real configured model and public sources",
        "dataset": {"name": args.cases_file.name, "sha256": hashlib.sha256(dataset).hexdigest()},
        "rows": list(results.values()),
    }
    output = Path(args.output).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"REPORT_FILE={output}", flush=True)


if __name__ == "__main__":
    main()
