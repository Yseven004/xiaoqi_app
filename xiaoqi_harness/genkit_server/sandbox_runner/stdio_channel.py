"""Bounded, bidirectional MCP framing over an isolated Docker attach socket.

The socket belongs to the trusted runner. Its peer is a container process, never
an API-host child process. Stderr is diagnostic data, not JSON-RPC traffic.
"""
from __future__ import annotations

import json
import queue
import threading
from typing import Any

MAX_MESSAGE_BYTES = 2 * 1024 * 1024
MAX_PENDING_MESSAGES = 16
MAX_DIAGNOSTIC_BYTES = 16 * 1024


class StdioChannel:
    def __init__(self) -> None:
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

    def send(self, message: dict[str, Any]) -> None:
        encoded = self._encode(message)
        with self._write_lock:
            if self.closed or self._socket is None:
                raise RuntimeError("MCP process is not connected")
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
        if reason is not None and not self.closed and self._error is None:
            self._error = reason
        self._closed.set()
        self._wake_poll()
        if self._socket is not None:
            try:
                self._socket.shutdown(2)
            except OSError:
                pass
            self._socket.close()

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
                    self._messages.put_nowait(message)
                if len(buffered) > MAX_MESSAGE_BYTES:
                    raise ValueError("MCP message exceeds transport byte budget")
        except (ValueError, UnicodeDecodeError, queue.Full):
            self._error = "MCP process emitted invalid data or exceeded transport budget"
        except OSError:
            if not self.closed:
                self._error = "MCP process connection interrupted"
        finally:
            self._closed.set()
            self._wake_poll()
