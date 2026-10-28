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
    def __init__(self, request: dict[str, Any], run: Callable, slots: Any, clock: Callable = time.monotonic):
        self.token = request["lease_token"]
        self.task_id = request["task_id"]
        self.issued_at = request["issued_at"]
        self.fingerprint = hashlib.sha256(json.dumps(request, sort_keys=True).encode()).hexdigest()
        self._clock = clock
        self.created = clock()
        self.last_activity = self.created
        self.finished_at: float | None = None
        self._activity_lock = threading.Lock()
        self.channel = StdioChannel()
        self.ready = threading.Event()
        self.done = threading.Event()
        self.result: dict[str, Any] | None = None
        self._events_lock = threading.Lock()
        self._event_sequence = 0
        self._event_batch: dict[str, Any] | None = None
        self._event_bytes = 0
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
            with self._activity_lock:
                self.finished_at = self._clock()
            slots.release()
            self.done.set()
            self.ready.set()

    def stop(self):
        self.channel.close()

    def heartbeat(self):
        with self._activity_lock:
            if not self.channel.closed:
                self.last_activity = self._clock()

    def expire(self, now: float, idle_seconds: float, max_lifetime: float):
        # Renewal and expiry share one lock: a fresh heartbeat cannot be killed
        # by an expiry decision made before it arrived.
        with self._activity_lock:
            if self.done.is_set() or self.channel.closed:
                return
            if now - self.created >= max_lifetime:
                self.channel.close("MCP session time budget exhausted")
            elif now - self.last_activity >= idle_seconds:
                self.channel.close("MCP lease heartbeat expired")

    def poll_events(self, cursor: int, timeout: float = 15) -> dict[str, Any]:
        """Acknowledge only on the next request; a lost HTTP response is replayable."""
        if type(cursor) is not int or cursor < 0:
            raise LeaseError("Invalid event cursor")
        with self._events_lock:
            if self._event_batch is not None and cursor == self._event_sequence - 1:
                self.heartbeat()
                return self._event_batch
            if cursor != self._event_sequence:
                raise LeaseError("Invalid event cursor")
            self.heartbeat()
            self._event_batch = None
            self._event_bytes = 0
            result = self.channel.poll(timeout=timeout)
            if result["messages"] or result.get("closed") or result.get("error"):
                self._event_sequence += 1
                self._event_batch = {**result, "cursor": self._event_sequence}
                self._event_bytes = len(json.dumps(self._event_batch, ensure_ascii=False).encode())
                return self._event_batch
            return {**result, "cursor": self._event_sequence}

    def discard(self):
        if self.done.is_set():
            with self._events_lock:
                self._event_batch = None
                self._event_bytes = 0
            self.channel.discard()
            if self.result is not None:
                self.result = {key: value for key, value in self.result.items()
                               if key in {"ok", "error", "cleanup_pending", "sandbox_id"}}

    @property
    def payload_bytes(self):
        if not self.done.is_set() or self.result is None:
            return self._event_bytes
        return self._event_bytes + sum(len(item.get("base64", "")) for item in self.result.get("artifacts", []))


class McpSessions:
    def __init__(self, run: Callable, slots: Any, lifetime: float = 120, *, max_lifetime: float = 4 * 60 * 60, retention: float = 120, clock: Callable = time.monotonic, wall_clock: Callable = time.time):
        self._run = run
        self._slots = slots
        self._lifetime = lifetime
        self._max_lifetime = max_lifetime
        self._retention = retention
        self._clock = clock
        self._wall_clock = wall_clock
        self._lock = threading.Lock()
        self._leases: dict[str, McpLease] = {}
        self._closed = threading.Event()
        self._sweeper: threading.Thread | None = None

    def create(self, request: dict[str, Any]) -> McpLease:
        lease_id = request.get("lease_id", "")
        token = request.get("lease_token", "")
        task_id = request.get("task_id", "")
        issued_at = request.get("issued_at")
        if type(issued_at) is not int or not -30 <= self._wall_clock() - issued_at <= 120:
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
                prior.heartbeat()
                return prior
            if (len(self._leases) >= 1024 or sum(lease.payload_bytes for lease in self._leases.values()) >= 32 * 1024 * 1024
                    or not self._slots.acquire(blocking=False)):
                raise LeaseError("Runner MCP capacity is exhausted")
            try:
                lease = McpLease(request, self._run, self._slots, self._clock)
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
            self._sweep_once()

    def _sweep_once(self):
        now = self._clock()
        wall_now = self._wall_clock()
        with self._lock:
            leases = list(self._leases.values())
            for key, lease in list(self._leases.items()):
                if (lease.done.is_set() and lease.finished_at is not None
                        and now - lease.finished_at >= self._retention
                        and wall_now - lease.issued_at > 120):
                    del self._leases[key]
            # Startup timestamps still prevent replay after pruning tombstones.
        for lease in leases:
            lease.expire(now, self._lifetime, self._max_lifetime)

    def close(self):
        self._closed.set()
        with self._lock:
            leases = list(self._leases.values())
        for lease in leases:
            lease.stop()
        for lease in leases:
            lease.done.wait(timeout=5)
