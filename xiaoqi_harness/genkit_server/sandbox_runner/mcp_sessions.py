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
from mcp_journal import McpJournal, McpJournalError


class LeaseError(ValueError):
    pass


class McpLease:
    def __init__(self, request: dict[str, Any] | None, run: Callable, slots: Any, clock: Callable = time.monotonic,
                 *, journal: McpJournal | None = None, lease_id: str | None = None,
                 saved: dict[str, Any] | None = None, wall_clock: Callable = time.time):
        self.journal = journal
        self.lease_id = lease_id or request['lease_id']
        self.token_hash = saved['token_hash'] if saved else hashlib.sha256(request['lease_token'].encode()).hexdigest()
        self.task_id = saved['task_id'] if saved else request['task_id']
        self.issued_at = saved['issued_at'] if saved else request['issued_at']
        self.fingerprint = saved['fingerprint'] if saved else hashlib.sha256(json.dumps(request, sort_keys=True).encode()).hexdigest()
        self._clock = clock
        self._wall_clock = wall_clock
        now = clock()
        wall = wall_clock()
        self.created = now - max(0, wall - saved['created_wall']) if saved else now
        self.last_activity = now - max(0, wall - saved['last_activity_wall']) if saved else now
        self.finished_at: float | None = now - max(0, wall - saved['finished_wall']) if saved and saved.get('finished_wall') else None
        if journal is not None and saved is None:
            journal.create(self.lease_id, task_id=self.task_id, token_hash=self.token_hash,
                           fingerprint=self.fingerprint, issued_at=self.issued_at, now=wall)
        self._activity_lock = threading.Lock()
        self.channel = StdioChannel(journal, self.lease_id)
        self.channel.fingerprint = self.fingerprint
        self._preserve_recovery = False
        if journal is not None:
            def checkpoint(result):
                try:
                    journal.patch(self.lease_id, phase='finishing', result=result)
                    # Cleanup may fail after the durable file checkpoint. Keep
                    # that exact result available to exception/reconcile paths.
                    self.result = result
                    self._preserve_recovery = False
                    self.channel.preserve_recovery = False
                except Exception:
                    self._preserve_recovery = True
                    raise
            self.channel.checkpoint = checkpoint
        self.ready = threading.Event()
        self.done = threading.Event()
        self.result: dict[str, Any] | None = saved.get('result') if saved else None
        self._events_lock = threading.Lock()
        self._event_sequence = 0
        self._event_batch: dict[str, Any] | None = None
        self._event_bytes = 0
        self._thread = None
        if saved and saved.get('phase') == 'finished':
            self.channel.close()
            self.done.set()
            self.ready.set()
        else:
            self._thread = threading.Thread(target=self._run, args=(request, run, slots), daemon=True)

    def start(self):
        if self._thread is not None:
            self._thread.start()

    def _run(self, request, run, slots):
        try:
            def event(value):
                if self.journal is not None and value.get('type') in {'sandbox_workspace_prepared', 'sandbox_started'}:
                    fields = {'phase': 'active' if value['type'] == 'sandbox_started' else 'prepared'}
                    if 'resources' in value:
                        fields['resources'] = value['resources']
                    if value['type'] == 'sandbox_workspace_prepared':
                        fields['workspace_prepared'] = True
                    self.journal.patch(self.lease_id, **fields)
                if value.get("type") == "sandbox_started":
                    self.ready.set()
            self.result = run(request if request is not None else {'lease_id': self.lease_id, **self.journal.get(self.lease_id)}, event, self.channel)
        except Exception:
            # Errors may contain user-defined environment values. The process
            # diagnostics remain separate from this public control error.
            if not self.channel.detached:
                self.result = {**(self.result or {}), "ok": (self.result or {}).get('ok', False),
                               "error": "Isolated MCP process failed; original outcome may be unknown",
                               "artifacts": (self.result or {}).get('artifacts', []), 'cleanup_pending': True}
        finally:
            try:
                if not self.channel.detached:
                    self.channel.close()
                    with self._activity_lock:
                        self.finished_at = self._clock()
                    if self.journal is not None and not self._preserve_recovery and not self.channel.preserve_recovery:
                        self.journal.patch(self.lease_id, phase='finished', result=self.result, finished_wall=self._wall_clock())
            finally:
                slots.release()
                self.done.set()
                self.ready.set()

    def stop(self):
        if self.journal is not None:
            self.journal.patch(self.lease_id, stopped=True)
        self.channel.close()

    def heartbeat(self):
        with self._activity_lock:
            if not self.channel.closed:
                self.last_activity = self._clock()
                if self.journal is not None:
                    self.journal.patch(self.lease_id, last_activity_wall=self._wall_clock())

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
            if self.journal is not None:
                state = self.journal.get(self.lease_id)
                if cursor != state['cursor'] and not (state.get('batch') is not None and cursor == state['cursor'] - 1):
                    raise LeaseError('Invalid event cursor')
                self.heartbeat()
                return self.journal.poll(self.lease_id, cursor, timeout)
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
            if self.journal is not None:
                self.journal.discard(self.lease_id)
            if self.result is not None:
                self.result = {key: value for key, value in self.result.items()
                               if key in {"ok", "error", "cleanup_pending", "sandbox_id"}}

    @property
    def result_ready(self):
        return self.done.is_set() and (self.journal is None or self.journal.get(self.lease_id).get('phase') == 'finished')

    @property
    def payload_bytes(self):
        if self.journal is not None:
            return self.journal.payload_bytes(self.lease_id)
        if not self.done.is_set() or self.result is None:
            return self._event_bytes
        return self._event_bytes + sum(len(item.get("base64", "")) for item in self.result.get("artifacts", []))


class McpSessions:
    def __init__(self, run: Callable, slots: Any, lifetime: float = 120, *, max_lifetime: float = 4 * 60 * 60, retention: float = 120, clock: Callable = time.monotonic, wall_clock: Callable = time.time,
                 db_path: str | None = None, recover: Callable | None = None):
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
        self._journal = McpJournal(db_path) if db_path is not None else None
        self._recover = recover
        self._recovery_lock = threading.Lock()

    def restore(self):
        if self._journal is None:
            return
        with self._lock:
            records = self._journal.all()
            # Serve the most recently live lease first. Older stopped/unfinished
            # cleanup records do not consume an extra running-process slot.
            records.sort(key=lambda entry: (
                entry[1].get('phase') == 'finished' or entry[1].get('closed') or entry[1].get('stopped'),
                -entry[1]['last_activity_wall']))
            for lease_id, saved in records:
                if lease_id in self._leases:
                    continue
                running = saved.get('phase') != 'finished'
                if running and self._recover is None:
                    raise LeaseError('Original MCP process recovery is unavailable')
                claimed = self._slots.acquire(blocking=False) if running else False
                cleanup_only = running and not claimed
                slots = self._slots
                if cleanup_only:
                    slots = threading.BoundedSemaphore(1)
                    slots.acquire()
                lease = McpLease(None, self._recover, slots, self._clock, journal=self._journal,
                                 lease_id=lease_id, saved=saved, wall_clock=self._wall_clock)
                self._leases[lease_id] = lease
                wall = self._wall_clock()
                if running:
                    if (cleanup_only or saved.get('stopped') or saved.get('closed') or
                            wall < saved['created_wall'] - 30 or
                            wall - saved['created_wall'] >= self._max_lifetime or
                            wall - saved['last_activity_wall'] >= self._lifetime):
                        lease.channel.close('Original MCP lease expired or was stopped')
                    lease.start()
                    if lease.channel.closed and not lease.done.wait(timeout=30):
                        raise LeaseError('Original MCP cleanup is still pending; data retained')
            if records and self._sweeper is None:
                self._sweeper = threading.Thread(target=self._sweep, daemon=True)
                self._sweeper.start()

    @property
    def active_lease_ids(self):
        with self._lock:
            if self._journal is not None:
                return {key for key, state in self._journal.all()
                        if state.get('phase') != 'finished' or (state.get('result') or {}).get('cleanup_pending')}
            return {key for key, lease in self._leases.items() if not lease.done.is_set()}

    def reconcile(self):
        if self._journal is None or self._recover is None or not self._recovery_lock.acquire(blocking=False):
            return
        try:
            if self._closed.is_set():
                return
            with self._lock:
                leases = list(self._leases.items())
            for lease_id, lease in leases:
                if not lease.done.is_set():
                    continue
                saved = self._journal.get(lease_id)
                if saved.get('phase') == 'finished' and not (saved.get('result') or {}).get('cleanup_pending'):
                    continue
                try:
                    # A finished/failed process is never relaunched here. The
                    # recovery helper only exports and removes its exact files.
                    lease.channel.close()
                    result = self._recover({'lease_id': lease_id, **saved}, lambda _: None, lease.channel)
                    self._journal.patch(lease_id, phase='finished', result=result, finished_wall=self._wall_clock())
                    lease.result = result
                    lease.finished_at = self._clock()
                except Exception:
                    # Keep the previous durable result and source resource IDs.
                    # Independent ordinary-code work remains available.
                    continue
        finally:
            self._recovery_lock.release()

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
                if not hmac.compare_digest(prior.token_hash, hashlib.sha256(token.encode()).hexdigest()) or prior.fingerprint != digest:
                    raise LeaseError("Lease already belongs to another request")
                # Includes completed/cancelled leases: no automatic process replay.
                prior.heartbeat()
                return prior
            if (len(self._leases) >= 1024 or sum(lease.payload_bytes for lease in self._leases.values()) >= 32 * 1024 * 1024
                    or not self._slots.acquire(blocking=False)):
                raise LeaseError("Runner MCP capacity is exhausted")
            try:
                lease = McpLease(request, self._run, self._slots, self._clock,
                                 journal=self._journal, wall_clock=self._wall_clock)
                self._leases[lease_id] = lease
                lease.start()
            except Exception:
                self._leases.pop(lease_id, None)
                if self._journal is not None and any(key == lease_id for key, _ in self._journal.all()):
                    self._journal.patch(lease_id, phase='finished', closed=True, finished_wall=self._wall_clock(),
                                        result={'ok': False, 'error': 'MCP startup did not complete', 'artifacts': []})
                self._slots.release()
                raise
            if self._sweeper is None:
                self._sweeper = threading.Thread(target=self._sweep, daemon=True)
                self._sweeper.start()
            return lease

    def get(self, lease_id: str, token: str) -> McpLease:
        with self._lock:
            lease = self._leases.get(lease_id)
            if lease is None or not isinstance(token, str) or not re.fullmatch(r"[a-f0-9]{64}", token) or not hmac.compare_digest(lease.token_hash, hashlib.sha256(token.encode()).hexdigest()):
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
                if (lease.done.is_set() and lease.result_ready and not (lease.result or {}).get('cleanup_pending') and lease.finished_at is not None
                        and now - lease.finished_at >= self._retention
                        and wall_now - lease.issued_at > 120):
                    del self._leases[key]
                    if self._journal is not None:
                        self._journal.delete(key)
            # Startup timestamps still prevent replay after pruning tombstones.
        for lease in leases:
            lease.expire(now, self._lifetime, self._max_lifetime)

    def close(self, *, detach: bool = False):
        with self._lock:
            if self._closed.is_set():
                return
            self._closed.set()
            leases = list(self._leases.values())
        for lease in leases:
            if detach and self._journal is not None and not lease.done.is_set():
                lease.channel.detach()
            else:
                lease.stop()
        for lease in leases:
            lease.done.wait(timeout=5)
        if self._journal is not None:
            if self._sweeper is not None and self._sweeper is not threading.current_thread():
                self._sweeper.join(timeout=5)
            with self._recovery_lock:
                self._journal.close()
