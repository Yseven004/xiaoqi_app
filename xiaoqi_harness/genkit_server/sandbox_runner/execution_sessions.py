"""Bounded execution identities and cancellation, including queued requests."""
from __future__ import annotations

import re
import threading
import time
from typing import Any


class ExecutionError(ValueError):
    pass


class Execution:
    def __init__(self, task_id: str, issued_at: int):
        self.task_id = task_id
        self.issued_at = issued_at
        self.cancelled = threading.Event()
        self.claimed = False
        self.done = False


class Executions:
    def __init__(self, capacity: int = 1024):
        self._lock = threading.Lock()
        self._entries: dict[str, Execution] = {}
        self._capacity = capacity
        # Requests from an earlier runner process must not be silently replayed.
        self._started_at = int(time.time() * 1000)

    def _get(self, request: dict[str, Any]) -> Execution:
        execution_id = request.get('execution_id')
        task_id = request.get('task_id')
        issued_at = request.get('issued_at')
        if not isinstance(execution_id, str) or not re.fullmatch(r'[a-f0-9]{32}', execution_id):
            raise ExecutionError('Invalid execution ID')
        if not isinstance(task_id, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,127}', task_id):
            raise ExecutionError('Invalid task ID')
        if type(issued_at) is not int:
            raise ExecutionError('Invalid execution timestamp')
        existing = self._entries.get(execution_id)
        if existing is not None:
            if existing.task_id != task_id or existing.issued_at != issued_at:
                raise ExecutionError('Execution belongs to another request')
            return existing
        now = time.time() * 1000
        if issued_at < self._started_at or not -30000 <= now - issued_at <= 120000:
            raise ExecutionError('Execution request has expired; do not replay an unknown result')
        # Finished/cancel-before-start tombstones outlive the startup acceptance
        # window. Pruning cannot make the old request eligible to execute again.
        for key, entry in list(self._entries.items()):
            if (entry.done or not entry.claimed) and now - entry.issued_at > 150000:
                del self._entries[key]
        if len(self._entries) >= self._capacity:
            raise ExecutionError('Execution registry capacity is exhausted')
        entry = Execution(task_id, issued_at)
        self._entries[execution_id] = entry
        return entry

    def claim(self, request: dict[str, Any]) -> Execution:
        with self._lock:
            entry = self._get(request)
            if entry.claimed:
                raise ExecutionError('Execution already submitted; do not replay an unknown result')
            entry.claimed = True
            return entry

    def cancel(self, request: dict[str, Any]) -> dict[str, Any]:
        with self._lock:
            entry = self._get(request)
            entry.cancelled.set()
            return {'ok': True, 'cancel_requested': True, 'finished': entry.done}

    def finish(self, entry: Execution) -> None:
        with self._lock:
            entry.done = True
