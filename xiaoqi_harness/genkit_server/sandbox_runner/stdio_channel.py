"""Bounded, bidirectional MCP framing over an isolated Docker attach socket.

The socket belongs to the trusted runner. Its peer is a container process, never
an API-host child process. Stderr is diagnostic data, not JSON-RPC traffic.
"""
from __future__ import annotations

import hashlib
import json
import logging
import queue
import threading
import traceback
from typing import Any
from mcp_journal import McpJournal, McpJournalError

MAX_MESSAGE_BYTES = 2 * 1024 * 1024
MAX_PENDING_MESSAGES = 16
MAX_DIAGNOSTIC_BYTES = 16 * 1024


class DockerAttachStream:
    """Preserve bytes prefetched while docker-py parses the upgrade headers."""
    def __init__(self, attached):
        self.socket = attached._sock
        self.response = attached._response
        self.reader = self.response.raw._fp.fp
        if not callable(getattr(self.reader, 'read1', None)):
            raise RuntimeError('Docker attach buffered reader is unavailable')
        # Drain only the already buffered upgrade prefix before publishing the
        # channel. Live reads stay on the socket, so cancellation never waits
        # behind a BufferedReader lock (notably on Windows socket.makefile).
        timeout = self.socket.gettimeout()
        try:
            self.socket.setblocking(False)
            try:
                prefetched = self.reader.peek(1)
            except BlockingIOError:
                prefetched = b''
            if len(prefetched) > MAX_MESSAGE_BYTES:
                raise RuntimeError('Docker attach upgrade prefix exceeds byte budget')
            self.prefix = bytearray(self.reader.read1(len(prefetched))) if prefetched else bytearray()
        finally:
            self.socket.settimeout(timeout)
        self.closed = False

    def recv(self, count):
        if self.prefix:
            result = bytes(self.prefix[:count])
            del self.prefix[:count]
            return result
        return self.socket.recv(count)

    def sendall(self, data):
        self.socket.sendall(data)

    def shutdown(self, how):
        self.socket.shutdown(how)

    def close(self):
        if self.closed:
            return
        self.closed = True
        try:
            try:
                self.socket.shutdown(2)
            except OSError:
                pass
            # Close the buffered HTTP owner before its raw SocketIO. Reversing
            # this order can also leave an invalid buffered-file finalizer.
            self.response.close()
        finally:
            self.socket.close()


class StdioChannel:
    def __init__(self, journal: McpJournal | None = None, lease_id: str | None = None) -> None:
        self.journal = journal
        self.lease_id = lease_id
        state = journal.get(lease_id) if journal is not None else {}
        self._replay_remaining = state.get('stdout_offset', 0)
        self._replay_hash = state.get('stdout_hash')
        self._stdout_hash = hashlib.sha256()
        self._stdout_offset = 0
        self._stdout_received = 0
        self._close_origin = 'none'
        self._replay_verified = threading.Event()
        if self._replay_remaining == 0:
            self._replay_verified.set()
        self.detached = False
        self.checkpoint = None
        self.preserve_recovery = False
        self._messages: queue.Queue[dict[str, Any] | None] = queue.Queue(MAX_PENDING_MESSAGES)
        self._write_lock = threading.Lock()
        self._poll_lock = threading.Lock()
        self._pending: dict[str, Any] | None = None
        self._socket: Any = None
        self._reader: threading.Thread | None = None
        self._closed = threading.Event()
        self._diagnostic = b""
        self._error: str | None = None
        self.exporter: Any = None

    @property
    def closed(self) -> bool:
        return self._closed.is_set()

    @property
    def error(self) -> str | None:
        return self._error

    @property
    def diagnostic(self) -> str:
        return self._diagnostic.decode("utf-8", errors="replace")

    def attach(self, raw_socket: Any) -> None:
        if self._socket is not None or self.closed:
            raise RuntimeError("stdio channel cannot be reused")
        self._socket = raw_socket
        self._reader = threading.Thread(target=self._read, daemon=True)
        self._reader.start()

    @staticmethod
    def _encode(message: dict[str, Any]) -> bytes:
        if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
            raise ValueError("Invalid JSON-RPC message")
        encoded = json.dumps(message, ensure_ascii=False, allow_nan=False, separators=(",", ":")).encode("utf-8")
        if len(encoded) > MAX_MESSAGE_BYTES:
            raise ValueError("MCP message exceeds transport byte budget")
        return encoded + b"\n"

    def send(self, message: dict[str, Any], sequence: int | None = None) -> None:
        encoded = self._encode(message)
        with self._write_lock:
            if self.closed or self._socket is None:
                raise RuntimeError("MCP process is not connected")
            if self.journal is not None:
                if not self._replay_verified.wait(20) or self.closed or self._error:
                    raise RuntimeError('Original MCP stdout could not be verified')
                if not self.journal.claim_send(self.lease_id, sequence, message):
                    return
            # Docker attach accepts raw stdin, while stdout/stderr are framed.
            self._socket.sendall(encoded)

    def poll(self, timeout: float = 15) -> dict[str, Any]:
        with self._poll_lock:
            return self._poll(timeout)

    def _poll(self, timeout: float) -> dict[str, Any]:
        messages = []
        try:
            message = self._pending if self._pending is not None else self._messages.get(timeout=0 if self.closed else timeout)
            if message is not None:
                messages.append(message)
            self._pending = None
        except queue.Empty:
            pass
        size = sum(len(self._encode(message)) for message in messages)
        while len(messages) < 32:
            try:
                message = self._messages.get_nowait()
                if message is None:
                    continue
                length = len(self._encode(message))
                if messages and size + length > MAX_MESSAGE_BYTES:
                    self._pending = message
                    break
                messages.append(message)
                size += length
            except queue.Empty:
                break
        return {"messages": messages, "closed": self.closed and self._pending is None and self._messages.empty(),
                **({"error": self.error} if self.error else {})}

    def discard(self) -> None:
        with self._poll_lock:
            self._pending = None
            while True:
                try:
                    self._messages.get_nowait()
                except queue.Empty:
                    break

    def close(self, reason: str | None = None) -> None:
        if self._replay_remaining and not self.closed:
            self._close_origin = ','.join(f'{frame.name}:{frame.lineno}' for frame in traceback.extract_stack(limit=4)[:-1])
        if reason is not None and not self.closed and self._error is None:
            self._error = reason
        self._closed.set()
        if self.journal is not None and not self.detached:
            self.journal.patch(self.lease_id, closed=True, error=self._error)
        self._wake_poll()
        if self._socket is not None:
            try:
                self._socket.shutdown(2)
            except OSError:
                pass
            self._socket.close()
        if self._reader is not None and self._reader is not threading.current_thread():
            self._reader.join(timeout=2)

    def detach(self) -> None:
        """Disconnect this runner process without stopping the original lease."""
        self.detached = True
        self._closed.set()
        self._wake_poll()
        if self._socket is not None:
            try:
                self._socket.shutdown(2)
            except OSError:
                pass
            self._socket.close()
        if self._reader is not None and self._reader is not threading.current_thread():
            self._reader.join(timeout=2)

    def _wake_poll(self) -> None:
        try:
            self._messages.put_nowait(None)
        except queue.Full:
            pass

    def _read_exact(self, count: int) -> bytes:
        result = bytearray()
        while len(result) < count:
            part = self._socket.recv(count - len(result))
            if not part:
                if result:
                    raise ValueError("Truncated Docker stream frame")
                return b""
            result.extend(part)
        return bytes(result)

    def _read(self) -> None:
        buffered = bytearray()
        try:
            while not self.closed:
                header = self._read_exact(8)
                if not header:
                    if buffered:
                        raise ValueError("MCP process exited with an incomplete message")
                    break
                kind = header[0]
                size = int.from_bytes(header[4:8], "big")
                if header[1:4] != b"\0\0\0" or kind not in {1, 2} or size > MAX_MESSAGE_BYTES:
                    raise ValueError("Invalid or oversized Docker stream frame")
                payload = self._read_exact(size)
                if len(payload) != size:
                    raise ValueError("Truncated Docker stream payload")
                if kind == 2:
                    self._diagnostic = (self._diagnostic + payload)[-MAX_DIAGNOSTIC_BYTES:]
                    continue
                self._stdout_received += len(payload)
                if self._replay_remaining:
                    count = min(self._replay_remaining, len(payload))
                    self._stdout_hash.update(payload[:count])
                    self._stdout_offset += count
                    self._replay_remaining -= count
                    payload = payload[count:]
                    if self._replay_remaining == 0:
                        if self._stdout_hash.hexdigest() != self._replay_hash:
                            raise ValueError('Original MCP stdout no longer matches its checkpoint')
                        self._replay_verified.set()
                buffered.extend(payload)
                while b"\n" in buffered:
                    line, _, remaining = buffered.partition(b"\n")
                    buffered = bytearray(remaining)
                    if len(line) > MAX_MESSAGE_BYTES:
                        raise ValueError("MCP message exceeds transport byte budget")
                    if not line.strip():
                        raise ValueError("Unexpected empty MCP stdout line")
                    message = json.loads(line.decode("utf-8"))
                    self._encode(message)
                    self._stdout_hash.update(line + b'\n')
                    self._stdout_offset += len(line) + 1
                    if self.journal is not None:
                        self.journal.receive(self.lease_id, message, self._stdout_offset, self._stdout_hash.hexdigest())
                    else:
                        self._messages.put_nowait(message)
                if len(buffered) > MAX_MESSAGE_BYTES:
                    raise ValueError("MCP message exceeds transport byte budget")
        except (ValueError, UnicodeDecodeError, queue.Full, McpJournalError):
            self._error = "MCP process emitted invalid data or exceeded transport budget"
        except OSError:
            if not self.closed:
                self._error = "MCP process connection interrupted"
        finally:
            if self._replay_remaining and not self.detached and self._error is None:
                self._error = 'Original MCP stdout checkpoint is unavailable'
            if self._replay_remaining and not self.detached:
                logging.getLogger(__name__).warning('MCP_REPLAY_FAILURE remaining=%s stdout_received=%s close_origin=%s',
                    self._replay_remaining, self._stdout_received, self._close_origin)
            self._closed.set()
            self._replay_verified.set()
            if self.journal is not None and not self.detached:
                self.journal.patch(self.lease_id, closed=True, error=self._error)
            self._wake_poll()
