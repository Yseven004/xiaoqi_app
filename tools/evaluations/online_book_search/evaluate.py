"""Evaluate the real book-search HTTP path in an isolated Genkit server."""

import base64
import gzip
import hashlib
import io
import json
import os
import posixpath
import re
import secrets
import shutil
import sqlite3
import subprocess
import tempfile
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
import uuid
import xml.etree.ElementTree as ET
import zipfile
from datetime import datetime, timezone


def norm(value):
    return " ".join(unicodedata.normalize("NFKC", value or "").lower().split())


def matches(value, expected, contains=False):
    value = norm(value)
    return any(norm(x) in value if contains else norm(x) == value for x in expected)


def ordinal(value):
    value = unicodedata.normalize("NFKC", value)
    if value.isdecimal():
        return int(value)
    digits = {c: i for i, c in enumerate("零一二三四五六七八九")}
    digits.update({"〇": 0, "○": 0})
    digits.update({str(i): i for i in range(10)})
    total = pending = 0
    for char in value:
        if char in digits:
            pending = pending * 10 + digits[char]
        else:
            total += (pending or 1) * {"十": 10, "百": 100}[char]
            pending = 0
    return total + pending


def section_key(value):
    return "".join(c for c in norm(value) if c.isalnum())


def check_sections(book, paths, case):
    """Match actual sections across EPUB spine boundaries, including packed novels."""
    names = case.get("sections", [])
    aliases = {
        section_key(name): i for i, entry in enumerate(names, 1)
        for name in entry.split("|")
    }
    count = case.get("chapters") or len(names)
    unit = {"回": "[回囘囬]", "本": "本", "篇": "篇", "章": "章"}.get(case.get("chapter_unit"))
    numbers = "[0-9一二三四五六七八九十百〇○零]{1,5}"
    prefix = re.compile(rf"^第\s*({numbers})\s*{unit}(?=$|[\s·、:：])") if unit else None
    suffix = re.compile(rf"^[\u3400-\u9fff]{{1,10}}第({numbers})(篇)?$") if unit == "篇" else None
    # Older printings sometimes omit 第. Require the same title spacing and the
    # next consecutive number to distinguish a heading from a prose reference.
    unprefixed = re.compile(
        rf"^({numbers}){unit}[^\S\n]{{2,}}[\u3400-\u9fff][\u3400-\u9fff\s]{{2,39}}$"
    ) if case.get("chapter_unit") == "回" else None
    # Some editions attach a chapter heading to the previous closing sentence.
    # Require the heading's typographic gap and a short title at the line end.
    inline_heading = re.compile(
        rf"(?<=[。！？])(?=第{numbers}{unit}[^\S\n]{{2,}}[\u3400-\u9fff]{{2,30}}\s*$)",
        re.MULTILINE,
    ) if unit else None
    body_chars = {}
    current = None
    for path in paths:
        doc = ET.fromstring(book.read(path))
        # Directory links and EPUB navigation can list all chapter names even
        # when the file only contains a table of contents.
        for parent in doc.iter():
            for node in list(parent):
                if node.tag.split("}")[-1] in {"nav", "footer", "script", "style", "a"}:
                    tail = node.tail
                    node.clear()
                    node.tail = tail
        for element in doc.iter():
            tag = element.tag.split("}")[-1]
            if tag == "div" and any(c.tag.split("}")[-1] in {"div", "p", "pre", "h1", "h2", "h3", "h4", "h5", "h6"} for c in element):
                continue
            if tag not in {"title", "h1", "h2", "h3", "h4", "h5", "h6", "p", "pre", "div"}:
                continue
            content = "".join(element.itertext()).strip()
            if inline_heading:
                content = inline_heading.sub("\n", content)
            for line in content.splitlines():
                line = line.strip()
                key = aliases.get(section_key(line))
                if prefix:
                    match = prefix.match(line) or (suffix and suffix.match(line))
                    if match:
                        key = ordinal(match[1])
                    elif unprefixed and (match := unprefixed.fullmatch(line)):
                        number = ordinal(match[1])
                        if number == (current or 0) + 1:
                            key = number
                if key is not None:
                    current = key if key > 0 else None
                    if current:
                        body_chars.setdefault(current, 0)
                elif current is not None and tag in {"p", "pre", "div"}:
                    body_chars[current] += sum(c.isalnum() for c in line)
    missing = [i for i in range(1, count + 1) if body_chars.get(i, 0) < 24]
    if missing:
        raise ValueError("missing_chapter_text_" + "_".join(map(str, missing[:8])))
    if case.get("exact_chapters") and any(n > count and chars >= 24 for n, chars in body_chars.items()):
        raise ValueError("unexpected_extra_chapters")
    return count


def check_file(resolved, case):
    data = base64.b64decode(resolved["epubBase64"], validate=True)
    if hashlib.sha256(data).hexdigest() != resolved["sha256"]:
        raise ValueError("file_checksum_mismatch")
    details = {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
    if case["format"] == "pdf":
        if not data.startswith(b"%PDF-") or b"%%EOF" not in data[-4096:]:
            raise ValueError("invalid_pdf_boundaries")
        if case.get("pdf_min_pages"):
            details.update(check_pdf(data, case))
    else:
        with zipfile.ZipFile(io.BytesIO(data)) as book:
            if book.testzip() or book.read("mimetype") != b"application/epub+zip":
                raise ValueError("invalid_epub_archive")
            container = ET.fromstring(book.read("META-INF/container.xml"))
            package_path = container.find(".//{*}rootfile").attrib["full-path"]
            package = ET.fromstring(book.read(package_path))
            spine = package.findall("./{*}spine/{*}itemref")
            manifest = {
                row.attrib["id"]: row.attrib["href"]
                for row in package.findall("./{*}manifest/{*}item")
            }
            parent = package_path.rpartition("/")[0]
            paths = []
            for item in spine:
                href = urllib.parse.unquote(manifest[item.attrib["idref"]])
                path = posixpath.normpath(posixpath.join(parent, href))
                if not book.getinfo(path).file_size:
                    raise ValueError("empty_epub_spine_document")
                paths.append(path)
            if not spine:
                raise ValueError("empty_epub_spine")
            if case.get("check_epub_metadata"):
                for field, tag in (("title", "title"), ("author", "creator")):
                    elements = package.findall(f"./{{*}}metadata/{{*}}{tag}")
                    if field == "author" and "author_attributions" in case:
                        expected = [
                            alias for group in case["author_attributions"]
                            if matches(resolved.get("author"), group) for alias in group
                        ]
                    else:
                        expected = case[field] + case.get(f"epub_{field}_aliases", [])
                    if not any(matches(e.text, expected, contains=field == "author") for e in elements):
                        raise ValueError(f"epub_{tag}_mismatch")
            if case.get("epub_translator"):
                contributors = package.findall("./{*}metadata/{*}contributor")
                if not any(matches(person.text, case["epub_translator"]) for person in contributors):
                    raise ValueError("epub_translator_mismatch")
            if case.get("epub_text_terms"):
                documents = (ET.fromstring(book.read(path)) for path in paths)
                text = norm(" ".join(
                    "".join(element.itertext())
                    for doc in documents
                    for element in doc.iter()
                    if element.tag.split("}")[-1] in {"p", "blockquote"}
                ))
                if not all(norm(term) in text for term in case["epub_text_terms"]):
                    raise ValueError("epub_body_sample_mismatch")
                details["epub_text_check"] = "matched"
            if case.get("chapters") or case.get("sections"):
                details["chapters"] = check_sections(book, paths, case)
            details["spine"] = len(spine)
    return details


def check_pdf(data, case):
    """Count pages and sample front and closing content."""
    info = shutil.which("pdfinfo")
    if info is None:
        try:
            from pypdf import PdfReader
            from pypdf.errors import PdfReadError
        except ImportError as error:
            raise ValueError("pdf_reader_unavailable_for_required_page_count") from error
        try:
            reader = PdfReader(io.BytesIO(data))
            if reader.is_encrypted:
                raise ValueError("pdf_page_tree_unreadable_or_encrypted")
            pages = len(reader.pages)
            if pages < case["pdf_min_pages"]:
                raise ValueError("pdf_page_count_below_full_reference")
            text_check = "not_configured"
            for label, first, last in (
                ("front", 0, min(pages, 12)),
                ("back", max(0, pages * 85 // 100 - 1), pages),
            ):
                terms = case.get(f"pdf_{label}_terms")
                if terms:
                    sample = norm(" ".join(p.extract_text() or "" for p in reader.pages[first:last]))
                    if not all(norm(term) in sample for term in terms):
                        raise ValueError(f"pdf_{label}_sample_mismatch")
                    text_check = "matched"
            return {"pdf_pages": pages, "pdf_text_check": text_check}
        except PdfReadError as error:
            raise ValueError("pdf_page_tree_unreadable_or_encrypted") from error
    extractor = shutil.which("pdftotext")
    reader = None
    if extractor is None and (case.get("pdf_front_terms") or case.get("pdf_back_terms")):
        try:
            from pypdf import PdfReader
            from pypdf.errors import PdfReadError
        except ImportError:
            pass
        else:
            try:
                reader = PdfReader(io.BytesIO(data))
            except PdfReadError as error:
                raise ValueError("pdf_text_reader_failed") from error
    environment = {**os.environ, "LC_ALL": "C"}
    with tempfile.TemporaryDirectory(prefix="xiaoqi-eval-pdf-") as directory:
        file = os.path.join(directory, "book.pdf")
        with open(file, "wb") as stream:
            stream.write(data)
        try:
            output = subprocess.check_output([info, file], env=environment, stderr=subprocess.DEVNULL, timeout=20)
            page_count = re.search(rb"^Pages:\s+(\d+)\s*$", output, re.MULTILINE)
            encrypted = re.search(rb"^Encrypted:\s+yes\b", output, re.MULTILINE)
            if not page_count or encrypted:
                raise ValueError("pdf_page_tree_unreadable_or_encrypted")
            pages = int(page_count[1])
            if pages < case["pdf_min_pages"]:
                raise ValueError("pdf_page_count_below_full_reference")
            text_check = "not_configured"
            ranges = (
                ("front", 1, min(pages, 12)),
                ("back", max(1, pages * 85 // 100), pages),
            )
            for label, first, last in ranges:
                terms = case.get(f"pdf_{label}_terms")
                if not terms:
                    continue
                if extractor is not None:
                    sample = subprocess.check_output(
                        [extractor, "-f", str(first), "-l", str(last), "-enc", "UTF-8", file, "-"],
                        env=environment, stderr=subprocess.DEVNULL, timeout=20,
                    ).decode("utf-8", "replace")
                elif reader is not None:
                    try:
                        sample = " ".join(page.extract_text() or "" for page in reader.pages[first - 1:last])
                    except PdfReadError as error:
                        raise ValueError("pdf_text_reader_failed") from error
                else:
                    text_check = "extractor_unavailable"
                    break
                sample = norm(sample)
                if not all(norm(term) in sample for term in terms):
                    raise ValueError(f"pdf_{label}_sample_mismatch")
                text_check = "matched"
        except (subprocess.SubprocessError, OSError) as error:
            raise ValueError("pdf_poppler_failed") from error
    return {"pdf_pages": pages, "pdf_text_check": text_check}


def candidate_matches(row, case):
    result = all(
        matches(row.get(key), case[key], contains=key in {"author", "edition"})
        for key in ("title", "author", "edition", "language", "publisher", "translator")
        if key in case
    )
    if case["kind"] != "file":
        return result
    source = urllib.parse.urlsplit(row.get("sourceUrl") or "")
    return (
        result
        and ("author_attributions" not in case or any(matches(row.get("author"), group) for group in case["author_attributions"]))
        and source.scheme == "https"
        and bool(source.hostname)
        and not source.username and not source.password
        and bool(row.get("sourceName"))
        and (not case.get("required_source_host") or source.hostname == case["required_source_host"])
        and bool(row.get("edition"))
        and bool(row.get("license"))
        and ("isbns" not in case or row.get("isbn") in case["isbns"])
        and row.get("format") == case.get("format", row.get("format"))
    )


class Evaluation:
    def __init__(self, root):
        self.root = root
        os.mkdir(root, 0o700)
        self.tenant = "book-search-evaluation"
        self.token = secrets.token_urlsafe(32)
        self.headers = {
            "x-xiaoqi-contract": "43",
            "Authorization": "Bearer " + self.token,
            "Content-Type": "application/json",
        }
        device = {
            "tenant_id": self.tenant,
            "device_id": self.tenant,
            "auth_method": "email",
            "account_email": self.tenant + "@invalid.local",
            "created_at": int(time.time()),
            "revoked_at": None,
        }
        with self.db() as db:
            db.execute("CREATE TABLE documents (key TEXT PRIMARY KEY, document TEXT NOT NULL, revision INTEGER NOT NULL)")
            key = "device/" + hashlib.sha256(self.token.encode()).hexdigest()
            db.execute("INSERT INTO documents VALUES(?,?,1)", (key, json.dumps(device)))

    def db(self):
        return sqlite3.connect(self.root + "/xiaoqi.sqlite3")

    def request(self, path, body=None, **headers):
        return urllib.request.Request(
            "http://127.0.0.1:8080" + path,
            headers={**self.headers, **headers},
            data=None if body is None else json.dumps(body).encode(),
        )

    def api(self, path, body=None, timeout=20, download_evidence=None):
        try:
            started = time.monotonic()
            with urllib.request.urlopen(self.request(path, body), timeout=timeout) as response:
                result = json.load(response)
                if not path.endswith("/resolve") or body is None:
                    return response.status, result
                prepared = time.monotonic()
                prepare_ms = round((prepared - started) * 1000)
                if result.get("verified") is not True or result.get("importable") is not True:
                    raise ValueError("resolve_did_not_verify_file")
                if download_evidence is not None:
                    download_evidence.update(stage="transfer", prepare_ms=prepare_ms)
                with urllib.request.urlopen(
                    self.request(path[:-len("resolve")] + "file"), timeout=timeout
                ) as file_response:
                    data = file_response.read(256 * 1024 * 1024 + 1)
                    expected_length = int(file_response.headers.get("Content-Length", "-1"))
                    digest = file_response.headers.get("X-Book-Sha256", "")
                if len(data) > 256 * 1024 * 1024:
                    raise ValueError("verified_file_above_256mib")
                if expected_length != len(data) or result.get("fileLength") != len(data):
                    raise ValueError("verified_file_length_mismatch")
                if not digest or hashlib.sha256(data).hexdigest() != digest or result.get("fileSha256") != digest:
                    raise ValueError("verified_file_sha256_mismatch")
                file_transfer_ms = round((time.monotonic() - prepared) * 1000)
                return 200, {
                    **result,
                    "epubBase64": base64.b64encode(data).decode("ascii"),
                    "sha256": digest,
                    "evaluation_timings": {
                        "prepare_ms": prepare_ms,
                        "file_transfer_ms": file_transfer_ms,
                    },
                }
        except urllib.error.HTTPError as error:
            return error.code, json.load(error)

    def agent(self, case, search_id, previous):
        metadata = {
            "task_id": search_id,
            "workflow_id": search_id,
            "user_message_id": search_id,
            "current_turn_text": case["prompt"],
            "book_search_id": search_id,
            "model_id": "deepseek-flash",
            "reasoning_level": "medium",
        }
        if case.get("linked"):
            metadata["book_search_linked_book"] = case["linked"]
        if previous:
            metadata["book_search_context_id"] = previous["search_id"]
            metadata["workflow_id"] = previous["search_id"]
        data = {
            "message": {
                "role": "user",
                "content": [{"text": case["prompt"]}],
                "metadata": {"xiaoqi_agent_turn": metadata},
            }
        }
        init = {"snapshotId": previous["snapshot"]} if previous else {}
        # A verified-search turn may perform five serial searches, each of
        # which can spend up to two minutes on source discovery/acquisition.
        end = time.monotonic() + 650
        final = {}
        finish = None
        with urllib.request.urlopen(
            self.request("/v1/agent/chat", {"data": data, "init": init}, Accept="text/event-stream"),
            timeout=640,
        ) as response:
            for line in response:
                if time.monotonic() > end:
                    raise TimeoutError("agent_stream_timeout")
                if not line.startswith(b"data: "):
                    continue
                frame = json.loads(line[6:])
                if "error" in frame:
                    finish = "stream_error"
                    break
                if "result" in frame:
                    final = frame["result"] or {}
                    finish = final.get("finishReason")
                    break
        with self.db() as db:
            row = db.execute(
                "SELECT document FROM documents WHERE key=?",
                (f"task/{self.tenant}/{search_id}",),
            ).fetchone()
        task = json.loads(row[0]) if row else {}
        tool_events = {e["tool"] for e in task.get("events", []) if e.get("tool")}
        answer = "".join(
            p.get("text", "")
            for p in (final.get("message") or {}).get("content", [])
            if not p.get("thought")
        )
        return {
            "finish": finish, "task": task.get("status"),
            "model_calls": task.get("model_request_runs", 0),
            "tools": sorted(tool_events), "snapshot": final.get("snapshotId"),
            "joined": task.get("book_search_reference") == search_id,
            "answer": answer[:900],
        }

    def run(self, case, results):
        started = time.monotonic()
        search_id = "eval-" + uuid.uuid4().hex
        path = "/v1/book-searches/" + search_id
        record = {
            "id": case["id"], "search_id": search_id, "pass": False,
            "started_at": datetime.now(timezone.utc).isoformat(),
        }
        try:
            if case.get("route") == "isbn":
                code, _ = self.api("/v1/book-searches", {"id": search_id, "query": case["prompt"]})
                if code not in {200, 201, 202}:
                    raise ValueError(f"isbn_start_http_{code}")
                record.update(model_calls=0, tools=[])
            else:
                previous = results.get(case.get("after"))
                if case.get("after") and (
                    not previous or not previous["joined"] or not previous.get("snapshot")
                ):
                    raise ValueError("prerequisite_search_missing")
                record.update(self.agent(case, search_id, previous))
                if record["finish"] != "stop" or record["task"] != "completed":
                    raise ValueError("agent_did_not_complete")
                if case["kind"] == "answer":
                    if record["tools"] or record["joined"]:
                        raise ValueError("qa_used_a_tool")
                    if not all(re.search(x, record["answer"], re.I) for x in case["answer_terms"]):
                        raise ValueError("answer_missing_required_facts")
                    record["pass"] = True
                    return record
                # Older isolated runs masked the new inspection action as
                # "tool". The current runtime publishes its actual identity.
                allowed = {"find_book_material", "inspect_book_source", "use_skill", "web_search", "web_fetch"}
                tools = set(record["tools"])
                if not record["joined"] or not tools.intersection(
                    {"find_book_material", "inspect_book_source"}
                ) or not tools.issubset(allowed):
                    raise ValueError("missing_book_search_tool_or_reference")
            for _ in range(90):
                code, snapshot = self.api(path)
                if code != 200:
                    raise ValueError(f"search_snapshot_http_{code}")
                if snapshot["status"] != "searching":
                    break
                time.sleep(0.4)
            rows = snapshot["candidates"]
            record.update(
                status=snapshot["status"],
                partial=snapshot.get("partial", False),
                attempts_used=snapshot.get("attemptsUsed"),
                attempts_remaining=snapshot.get("attemptsRemaining"),
                exhausted=snapshot.get("exhausted", False),
            )
            record["search_and_reply_ms"] = round((time.monotonic() - started) * 1000)
            fields = ("id", "title", "author", "edition", "language", "publisher", "translator", "format", "sourceUrl", "sourceName", "isbn", "downloadable", "preparationRequired", "preparationStatus", "importable", "verified", "fileLength", "availability", "license", "confirmationReason")
            record["candidates"] = [{key: row[key] for key in fields if key in row} for row in rows]
            if snapshot["status"] != "complete":
                raise ValueError("sources_" + snapshot["status"])
            eligible = [r for r in rows if r.get("downloadable") is True and not r.get("confirmationReason")]
            if case.get("requested_file"):
                exact_metadata = any(
                    candidate_matches(r, {**case, "kind": "metadata"}) and r.get("author")
                    for r in rows
                )
                outcome = "no_result"
                if eligible:
                    outcome = "file_entry"
                elif any(r.get("confirmationReason") for r in rows):
                    outcome = "alternative_requires_confirmation"
                elif exact_metadata:
                    outcome = "book_metadata_only"
                elif rows:
                    outcome = "web_lead_only"
                record["import_outcome"] = outcome
            def resolve(row, download_evidence=None):
                return self.api(
                    path + "/candidates/" + urllib.parse.quote(row["id"], safe="") + "/resolve",
                    {}, timeout=105, download_evidence=download_evidence,
                )
            if case["kind"] == "file" or (case.get("requested_file") and eligible):
                correct = [
                    row for row in eligible
                    if candidate_matches(row, {**case, "kind": "file"})
                ]
                if not correct:
                    raise ValueError("metadata_mismatch" if eligible else "no_downloadable_candidate")
                record["download_entry_found"] = True
                record["extra_importable_candidates"] = len(eligible) - len(correct)
                chosen = correct[0]
                download = {
                    "candidate_id": chosen["id"], "stage": "prepare",
                    "source": chosen["sourceUrl"],
                }
                record["download"] = download
                download_started = time.monotonic()
                try:
                    code, data = resolve(chosen, download)
                    download["http_status"] = code
                    if code != 200:
                        error = data.get("error") if isinstance(data, dict) else None
                        message = error.get("message") if isinstance(error, dict) else None
                        if isinstance(message, str):
                            download["message"] = re.sub(r"https?://\S+", "[URL]", message)[:160]
                        raise ValueError(f"{'resolve' if download['stage'] == 'prepare' else 'file'}_http_{code}")
                    record.update(data.get("evaluation_timings", {}))
                    download["stage"] = "check_content"
                    if data.get("id") != chosen["id"] or not candidate_matches(data, {**case, "kind": "file"}):
                        raise ValueError("resolved_edition_mismatch")
                    download["source"] = data["sourceUrl"]
                    record["file"] = check_file(data, {**case, "format": chosen["format"]})
                    download["stage"] = "complete"
                    if case.get("requested_file"):
                        record["import_outcome"] = "verified_file"
                finally:
                    download["ms"] = round((time.monotonic() - download_started) * 1000)
                record["client_import_verified"] = False
                if record["extra_importable_candidates"]:
                    raise ValueError("wrong_file_offered")
            elif case["kind"] == "catalog":
                if eligible:
                    raise ValueError("catalog_exposed_import")
                exact = [r for r in rows if candidate_matches(r, case)]
                if {r.get("isbn") for r in exact} != set(case["isbns"]):
                    raise ValueError("missing_or_wrong_catalog_edition")
                if not all(r.get("sourceUrl") and r.get("edition") for r in exact):
                    raise ValueError("catalog_missing_source_or_edition")
                if resolve(exact[0])[0] != 409:
                    raise ValueError("catalog_resolve_not_rejected")
            elif case["kind"] == "no_file" and eligible:
                raise ValueError("unexpected_importable_candidate")
            elif case["kind"] == "discovery" and not rows:
                raise ValueError("discovery_returned_no_candidates")
            record["pass"] = True
        except (ValueError, OSError, KeyError, TypeError, ET.ParseError, zipfile.BadZipFile) as error:
            # Avoid dumping HTTP exceptions, which can contain signed URLs.
            record["reason"] = str(error) if type(error) is ValueError else type(error).__name__
        finally:
            record["ms"] = round((time.monotonic() - started) * 1000)
            record["ended_at"] = datetime.now(timezone.utc).isoformat()
        return record


def main(cases, release):
    evaluation = Evaluation(os.environ["XIAOQI_DATA_DIR"])
    server = subprocess.Popen(["/app/bin/server"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    results = {}
    try:
        for _ in range(60):
            try:
                code, health = evaluation.api("/health")
                if code == 200:
                    break
            except OSError:
                pass
            if server.poll() is not None:
                raise RuntimeError("evaluation server exited")
            time.sleep(0.25)
        else:
            raise RuntimeError("evaluation server did not become healthy")
        for case in cases:
            results[case["id"]] = evaluation.run(case, results)
            row = results[case["id"]]
            print(f"{row['id']} {'PASS' if row['pass'] else row['reason']}", flush=True)
        report = {"release": release, "health": health, "rows": list(results.values())}
        packed = gzip.compress(json.dumps(report, ensure_ascii=False).encode())
        encoded = base64.b64encode(packed).decode()
        for i in range(0, len(encoded), 2000):
            print("REPORT " + encoded[i:i + 2000], flush=True)
    finally:
        server.terminate()
        try:
            server.wait(timeout=10)
        except subprocess.TimeoutExpired:
            server.kill()
