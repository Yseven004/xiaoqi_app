# MCP runner recovery — deployed and verified

Problem: runner restart previously lost in-memory leases and removed their
containers/workspaces. This batch retains the original process, private transport
state and task/source binding. It does not complete all P07/P13 recovery work.

Implemented and wired locally:

- Private SQLite journal in the existing runner data volume, FULL synchronous
  commits, token/startup hashes, original wall-time deadlines, inbound frames,
  poll batches/cursors and send sequence/payload hashes. Startup environment and
  raw lease tokens are not copied into journal metadata.
- Outgoing messages are serialized. A protocol-v2 capability handshake permits
  control HTTP retries with the exact original sequence. Claims precede stdin
  writes; duplicate request IDs and lost acknowledgements cannot resend an effect.
  Claimed-but-unconfirmed delivery remains unknown rather than being replayed.
- Restore matches original owner/task/lease/startup-fingerprint Docker labels and
  container ID. Original stdout history is checked by byte count and SHA-256 before
  sending new messages. UTF-8 chunk boundaries, changed/truncated history and lost
  poll responses have executable coverage. Bounded MCP logs use 64 MiB; missing
  history closes the transport and preserves files instead of replaying requests.
- Graceful frontend detach retains the original process. Stop/expiry terminates it
  before export. Original files are committed before cleanup. Later cleanup errors
  preserve those committed files; failed storage retains original workspaces.
  Background reconciliation retries cleanup without restarting plugin commands.
- Cursor-independent status allows API artifact recovery. Result ACK follows
  API-side file persistence. Reopening an acknowledged result cannot resurrect files
  or start the original command again.
- Legacy task-bound resources without lease/execution labels are frozen and
  retained during startup cleanup. Their identity is insufficient to restore RPCs;
  authenticated legacy-file reconciliation remains outstanding. They are not
  silently deleted or presented as successfully recovered sessions.

Local evidence: 81 runner tests pass, including durable registry reopen, original
deadline preservation, wrong token/source rejection, stop/result/ACK persistence,
cleanup failure, label validation, read-only original-volume export, and detach.
Two focused Dart transport/API recovery tests and all 383 Dart tests pass; static
analysis reports no issues. Deployment Python discovery passes 28 tests with 16
Linux-only cases skipped locally; CI must run those on Linux.
These tests do not substitute for real Docker acceptance.

First CI run 40804928902/job 123221478720 passed image build, Dart/runner/deploy
checks, the existing real stdio-runtime gate and ordinary runner-restart gate.
The new MCP fixture timed out before the host restart because it ignored the
SDK's initial `server/discover` request. The fixture now returns JSON-RPC -32601
for unknown request methods (notifications remain unanswered). A native real-SDK
smoke against this exact Node fixture passes initialization, tool listing, delayed
call, original input and one effect. Three additional transport regressions pass:
unavailable durable capability, immutable serialized concurrent sends, and no
later submission after an explicit first-send rejection. Fresh Docker acceptance
remains required; the failed CI did not replace production.

Second CI 40807355855/job 123229372545 passed initialization and reached the
pending-call marker, but the SDK connection closed after the real runner restart.
The original container remained running at the host checkpoint; therefore this
is unresolved recovery behavior, not successful acceptance. A new real-SDK HTTP
and durable-registry restart test passes locally with one original effect. The
remaining reproduction is Docker-specific. Failure handling now captures bounded
CI-runner logs and filtered journal state before cleanup, and structural exception
frames omit exception text/arguments/environment. Restart verification runs before
the longer unchanged standard stdio gate, so a failure is diagnosed earlier; every
existing gate and resource-leak check remains required. Production is unchanged.

Root cause identified from the installed docker-py ContainerConfig encoder:
`stdin_open=True` with its default `detach=False` serializes `StdinOnce=True`.
Disconnecting the first runner attach therefore closes the original plugin stdin;
a delayed response can keep its process briefly alive while the input is already
lost. MCP create now sets `detach=True` with `stdin_open=True`, producing
`OpenStdin=True, StdinOnce=False`. A test exercises the actual docker-py encoder
and contrasts the previous failing defaults; the real gate inspects the Engine's
recorded configuration before killing the runner. The active original-container
reattach helper also has a real framed-socket test with durable historical stdout,
the next request and pre-cleanup file checkpoint. Docker reacceptance is pending.

CI 40817105183/job 123260878932 for main 3c1fbd6d3347b9e78cbffe868de54518fc14d6a3
completed successfully: all 387 Dart, 82 runner and 28 deployment checks pass.
The real MCP restart gate resumes the original pending SDK call with one effect,
the original container/input snapshot and hash-verified artifact. Ordinary restart,
the existing real stdio-runtime gate, resource cleanup and image export/import
roundtrip also pass. The standard non-image production deployment is in progress;
this CI evidence alone does not claim deployed effectiveness.

Production release 20261029-122110-3c1fbd6 completed the standard non-image
deployment with exit 0. Runtime checks, activation/data checks, current health,
the latest-good emergency restore point and restore data passed. Public HTTPS
health returned 200 through Cloud Assistant after the local Windows TLS probe
failed. Product/API remain 2026-10-27-agent-tools-2/24. Deployment log:
`C:/Users/20833/Desktop/xiaoqi_app/.codex-artifacts/deploy/20261029-122110-3c1fbd6.log`.
This does not claim client/device verification, legacy-file reconciliation or
API-process pending-RPC correlation. The overall P01–P14 goal remains active.

Real Docker gate added to the existing isolated CI flow: a Dart SDK call writes
one counter, the host SIGKILL-restarts only the CI runner, then verifies the same
container/process boot identity, original input/source hash, original pending RPC,
continued calls, one effect, artifact hash and final resource cleanup. It uses no
paid model/image API. This gate must pass before deployment is claimed.

Remaining outside this batch: legacy-file reconciliation; API-process restart
correlation of pending SDK RPCs (distinct from runner restart); broader P11 adapters
and full-plan client/platform acceptance. Do not close the overall goal on this batch.

Deployment uses the normal main/CI artifact pipeline. No new provider, machine,
general computer/mobile controller or external service is introduced. Existing
uid 10001, read-only rootfs, capability and network isolation remain in force.

References reviewed 2026-10-29:
[Docker Engine API 1.45](https://docs.docker.com/reference/api/engine/version/v1.45/),
[pinned MCP transport specification](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports).
The locked SDK wire negotiation is unchanged.
