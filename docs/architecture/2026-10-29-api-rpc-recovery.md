# API restart: collect the original MCP result

The API previously persisted lease credentials and recovered files but could
lose a pending RPC response after process death. This batch correlates a reserved
task operation with the original lease and typed JSON-RPC ID before submission.
The private record contains hashes and bindings, not a new execution grant.
Incoming correlated responses are persisted before the event cursor can be
acknowledged. An already confirmed response cannot be downgraded by a late error.

On API recovery, reconcile already saved responses first, then read pending
responses only from that original lease, within the persisted original deadline
and a monotonic 60-second ceiling. No SDK initialization, replacement process,
tool submission or new budget reservation occurs during this recovery. Normalize
and persist the original result before lease acknowledgement and private-journal
cleanup. If a result is genuinely unavailable, preserve files and retain an
unknown operation that cannot be replayed. An unsuccessful recovery read closes
its HTTP client without stopping a still-recoverable original process.

The journal is task/tenant/lease scoped, bounded by existing operation limits
and 32 MB of retained responses. Completed records are pruned only after a
matching task outcome is durable. Old leases without RPC records retain the
existing artifact-only recovery. No client API or user interaction changes.
Source withdrawal, cancellation and authorization checks still gate new effects.

Local verification: all 18 focused checks pass, including forced API process
termination after actual SDK/HTTP submission and one-time result/budget recovery,
lost cursor checkpoint, mismatched typed IDs, conflicting responses, expiry,
late errors, lease/file recovery, authority revocation and alias uncertainty.
Full Dart analysis passes. Python gate syntax compiles. Real Docker proof and
exact-commit CI/deployment are pending; local HTTP proof is not Docker proof.

The CI gate launches an actual isolated Node MCP server, observes its one-effect
counter and boot/input identity, kills the API container before the delayed
response, reconstructs the API from the original SQLite volume and verifies the
original response, process identity, files and single budget charge. Existing
runner-restart/stdio/source-mode/long-build and clean-resource gates remain.
No paid model/image calls, extra devices or production Docker socket access are
introduced. Rollback uses the standard deployment restore point; new private
documents do not alter existing package or client formats.

Protocol references reviewed 2026-10-29 (reference only; no upstream code copied):
- https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle
- https://modelcontextprotocol.io/specification/2025-11-25/server/tools

Response collection uses Xiaoqi's existing private runner channel, not a claim
that MCP standard initialization itself resumes an old SDK session. Hooks/apps/
extensions, legacy unbound files and other remaining plan work stay open.

Pre-release review found the runner's durable JSON serialization sorts keys.
Request/response digests now recursively canonicalize object keys, preserving
list order and typed IDs. The response replay regression includes reordered
nested keys and still rejects changed values. All 18 focused checks and full
analysis pass after this fix. Superseded CI 40847214311 was explicitly cancelled;
its deploy controller exited before production changes. It is not counted as a
passing build or a deployment failure after activation.

Recovery now receives the existing Agent cancellation token. Cancellation closes
the original lease immediately, then persists its available files and unknown
outcome; it does not wait for the reply deadline or submit another RPC. The
additional forced-process-death/cancellation case brings the focused suite to
19 passing checks. Original file bytes are asserted for both completion and
cancellation. Full analysis remains clean. Superseded CI 40848175372 was cancelled
before activation to include this cancellation path; its controller exited with
production unchanged. The exact final commit still requires real-container CI.

Final-commit CI 40849378098/job 123364737377 (main
b70c2c31f75a7a0d468d5f098e407dc358c3fa58) passes all 403 Dart, 86 runner and
30 deployment tests, including both actual API-child-death cases. Image build
succeeds. The existing real Docker runner-restart gate then fails before the new
API-container gate runs: original SDK request 3 reaches its 30-second timeout;
the retained runner state reports "Original MCP stdout checkpoint is unavailable",
stdout_offset 442, cursor 4, send_sequence 5, closed/stopped/finished. The host
had verified the original container remained running after runner restart.
This is not yet a diagnosed root cause or an accepted flaky rerun.

The standard deploy controller exits 1 in the build phase and explicitly leaves
production unchanged. No artifact activation or production rollback was needed.
The prior healthy release remains 20261029-145118-3c9ead8. Next required work:
distinguish a missing Docker stdout replay prefix from an API-initiated close or
event/cursor error, reproduce with private cursor journaling enabled, fix the
actual cause, then rerun all original and new real-container gates. Do not remove
the runner-restart gate or call this batch deployed from the green unit suite.

Released and verified: main bf0f896c5cee28b90604cd84da54ec0a9e920f41,
CI 40858154228/job 123394287817 passes all 407 Dart, 87 runner and 30 deployment
checks. Both real runner-restart and API-container-death gates pass with the
original process, response, input/files and one effect/budget charge. Standard
stdio, source modes, long builds, resource cleanup and image roundtrip pass.
Release 20261029-183110-bf0f896 completes standard non-image deployment with
exit 0, healthy service/data, latest-good restore data and public HTTPS 200 via
Cloud Assistant after local Windows TLS checking failed. Product/API stay
2026-10-27-agent-tools-2/24. Log:
C:/Users/20833/Desktop/xiaoqi_app/.codex-artifacts/deploy/20261029-183110-bf0f896.log.
No client rebuild or paid image check is required by this server-only change.
Remaining full-plan work and user device acceptance stay open.
