# Preserve Docker attach's prefetched HTTP bytes

CI 40849378098 failed the original runner-restart gate with an unavailable
442-byte stdout checkpoint. The original container was still running. Native
real SDK/HTTP/durable-registry restart passes both with and without the new API
cursor journal, so that narrower test alone could not explain the Docker failure.

Root cause reproduced using the pinned docker-py 7.1.0 APIClient and a real local
HTTP 101 upgrade: when headers and stdout arrive together, the HTTP reader has
already buffered the stdout prefix. Reading attached._sock bypasses that buffer.
The raw socket timed out while the original prefix was present in the HTTP
buffer. This explains why previous timing-dependent Docker gates could pass.

Both initial and recovered MCP connections now use one DockerAttachStream.
Before publishing the channel, it nonblockingly drains the existing HTTP-reader
prefix into bounded memory, restores the socket timeout, and then uses the
socket for live reads and literal stdin writes. The same byte stream still goes
through existing framing, prefix SHA validation, duplicate-send and cursor rules.
Missing or changed history still fails closed. No RPC or external effect is
resubmitted and no authorization or resource limit is relaxed.

Using the BufferedReader itself for every live read was tried locally but
exposed a Windows socket.makefile shutdown/close wait. That variant is not the
final implementation. Only draining the initial buffer avoids a blocking buffered
read while another thread closes it. The wrapper owns shutdown and closes the
HTTP owner before the underlying raw stream, including normal cleanup and detach.

The new regression uses the actual docker-py HTTP-upgrade parser, not a modeled
Docker byte stream: it proves the old raw socket misses the prefetched prefix,
then verifies exact original history, the pending response and live stdin with
the adapter. All 87 runner checks pass in 7.548 seconds. All 21 focused Dart
recovery/authority checks and full Dart analysis pass. New structural failure
diagnostics include phase/type/cursor and replay byte counts/caller frames only;
they never print RPC bodies, credentials, environment values or exception text.
Real Docker and exact-commit deployment acceptance remain pending.

References reviewed 2026-10-29, reference only, no upstream code copied:
- https://github.com/docker/docker-py/blob/7.1.0/docker/api/client.py
- https://docs.python.org/3/library/io.html#io.BufferedReader.read1

The dependency remains docker==7.1.0. This server/runner-only fix changes no
public API, client data or package formats. Standard deployment retains automatic
rollback and one emergency restore point. The existing runner and new API restart
gates must both pass; neither is removed or weakened.
