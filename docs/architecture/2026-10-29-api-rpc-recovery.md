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
