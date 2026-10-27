"""Task-bound leases for isolated stdio servers; no host subprocess execution."""
from __future__ import annotations

import hashlib
import hmac
import json
import re
import threading
import time
from typing import Any, Callable

from stdio_channel import StdioChannel


class LeaseError(ValueError):
    pass


class McpLease:
    def __init__(self, request: dict[str, Any], run: Callable, slots: Any):
        self.token = request["lease_token"]
        self.task_id = request["task_id"]
        self.fingerprint = hashlib.sha256(json.dumps(request, sort_keys=True).encode()).hexdigest()
        self.created = time.monotonic()
        self.channel = StdioChannel()
        self.ready = threading.Event()
        self.done = threading.Event()
        self.result: dict[str, Any] | None = None
        self._thread = threading.Thread(target=self._run, args=(request, run, slots), daemon=True)

    def start(self):
        self._thread.start()

    def _run(self, request, run, slots):
        try:
            def event(value):
                if value.get("type") == "sandbox_started":
                    self.ready.set()
            self.result = run(request, event, self.channel)
        except Exception:
            # Errors may contain user-defined environment values. The process
            # diagnostics remain separate from this public control error.
            self.result = {"ok": False, "error": "Isolated MCP process failed", "artifacts": []}
        finally:
            self.channel.close()
            self.ready.set()
            self.done.set()
            slots.release()

    def stop(self):
        self.channel.close()

    def discard(self):
        if self.done.is_set():
            self.channel.discard()
            if self.result is not None:
                self.result = {key: value for key, value in self.result.items()
                               if key in {"ok", "error", "cleanup_pending", "sandbox_id"}}

    @property
    def payload_bytes(self):
        if not self.done.is_set() or self.result is None:
            return 0
        return sum(len(item.get("base64", "")) for item in self.result.get("artifacts", []))


class McpSessions:
    def __init__(self, run: Callable, slots: Any, lifetime: float = 120):
        self._run = run
        self._slots = slots
        self._lifetime = lifetime
        self._lock = threading.Lock()
        self._leases: dict[str, McpLease] = {}
        self._closed = threading.Event()
        self._sweeper: threading.Thread | None = None

    def create(self, request: dict[str, Any]) -> McpLease:
        lease_id = request.get("lease_id", "")
        token = request.get("lease_token", "")
        task_id = request.get("task_id", "")
        issued_at = request.get("issued_at")
        if type(issued_at) is not int or not -30 <= time.time() - issued_at <= 120:
            raise LeaseError("MCP startup request has expired")
        if not isinstance(lease_id, str) or not re.fullmatch(r"[a-f0-9]{32}", lease_id):
            raise LeaseError("Invalid lease ID")
        if not isinstance(token, str) or not re.fullmatch(r"[a-f0-9]{64}", token):
            raise LeaseError("Invalid lease token")
        if not isinstance(task_id, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", task_id):
            raise LeaseError("Invalid task ID")
        with self._lock:
            if self._closed.is_set():
                raise LeaseError("Runner is shutting down")
            prior = self._leases.get(lease_id)
            if prior is not None:
                digest = hashlib.sha256(json.dumps(request, sort_keys=True).encode()).hexdigest()
                if not hmac.compare_digest(prior.token, token) or prior.fingerprint != digest:
                    raise LeaseError("Lease already belongs to another request")
                # Includes completed/cancelled leases: no automatic process replay.
                return prior
            if (len(self._leases) >= 1024 or sum(lease.payload_bytes for lease in self._leases.values()) >= 32 * 1024 * 1024
                    or not self._slots.acquire(blocking=False)):
                raise LeaseError("Runner MCP capacity is exhausted")
            try:
                lease = McpLease(request, self._run, self._slots)
                self._leases[lease_id] = lease
                lease.start()
            except Exception:
                self._leases.pop(lease_id, None)
                self._slots.release()
                raise
            if self._sweeper is None:
                self._sweeper = threading.Thread(target=self._sweep, daemon=True)
                self._sweeper.start()
            return lease

    def get(self, lease_id: str, token: str) -> McpLease:
        with self._lock:
            lease = self._leases.get(lease_id)
            if lease is None or not isinstance(token, str) or not re.fullmatch(r"[a-f0-9]{64}", token) or not hmac.compare_digest(lease.token, token):
                raise LeaseError("MCP lease not found")
            return lease

    def _sweep(self):
        while not self._closed.wait(1):
            with self._lock:
                expired = [lease for lease in self._leases.values()
                           if time.monotonic() - lease.created > self._lifetime]
                for key, lease in list(self._leases.items()):
                    if lease.done.is_set() and time.monotonic() - lease.created > self._lifetime + 120:
                        del self._leases[key]
                # Startup timestamps prevent replay even after pruning tombstones.
            for lease in expired:
                lease.stop()

    def close(self):
        self._closed.set()
        with self._lock:
            leases = list(self._leases.values())
        for lease in leases:
            lease.stop()
        for lease in leases:
            lease.done.wait(timeout=5)
