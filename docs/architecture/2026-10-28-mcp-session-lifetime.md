# Separate MCP connection lifetime from script execution timeout

Both the container loop and MCP lease sweeper previously stopped stdio processes 120 seconds after creation. A live connection could therefore disappear while an Agent was still thinking or making successive tool calls, despite valid event polling.

Ordinary script executions retain the existing 120-second deadline. An MCP host instead has a 120-second owner-idle timeout and an independent four-hour absolute session budget. Valid event polling, accepted JSON-RPC messages and successful artifact snapshots renew activity; an authenticated duplicate startup renews only the same existing lease and never starts another process. Bare lookups, wrong credentials and invalid event cursors do not renew it. Renewal and idle expiry use the same lock, preventing a stale expiry decision from killing a newly renewed connection. Cancellation/normal close cannot be renewed back into life. The existing 256 MiB/.25 CPU/32 PID MCP container limits, isolation and concurrency capacity are unchanged.

Session age/idle durations use monotonic time. Completed results retain their existing 120-second recovery window measured from completion, not creation. A tombstone is also kept while its original startup timestamp could still pass the existing wall-clock replay window, including permitted caller clock skew. Capacity is released before the terminal done signal. Timeout reasons distinguish lost owner heartbeat from the absolute session budget.

This is the application's private runner process lease, not an MCP HTTP `Mcp-Session-Id`. It does not change negotiated protocol. Reference: the official [MCP SDK transport ownership/close documentation](https://ts.sdk.modelcontextprotocol.io/v2/clients/connect) distinguishes connection teardown from individual requests. The numeric budgets here are application policy, not values mandated by MCP. No SDK code is copied and pinned dependencies remain unchanged.

Related request-timeout correction: the outer tool call already allowed 60 seconds, but remote/stdio SDK configurations cut it off first at 15/20 seconds. Both SDK configurations and the outer call now share the same 60-second constant. Initialization and catalog reads retain their separate 20-second guards; the stdio initialization path gets an explicit guard so raising the SDK tool budget does not lengthen connection setup. A real Genkit/mock-MCP scenario returns after 16 seconds to cross the old remote cutoff, using the application's actual server configuration.

Local validation: 58 runner tests pass and Dart analyzer reports no issues. Fake clocks cover active polling beyond the old creation deadline, idle loss, absolute expiry despite heartbeats, completion-based retention and startup replay skew. Real HTTP tests check valid activity renewal and wrong-token rejection. The container-loop test keeps the ordinary script deadline while allowing MCP to continue. Local Docker is unavailable, so the actual long-duration container check is not claimed as run locally.

The final complete Dart regression passes 301 tests, including the 16-second MCP request through the actual Genkit loop and application SDK timeout configuration. Existing approval/denial, scope-change, recovery and per-task provider-count assertions remain active. This fixture makes no paid model or image calls. Runtime Docker timing is still a separate CI gate.

The real Docker gate now holds the official filesystem MCP connection for 125 seconds, then reads the same original file and verifies bytes before cancellation/artifact/cleanup checks. Its final JSON records the active observed duration and success only after that call. The stopwatch stops at the verified live call, excluding later unrelated gate work. This adds about two minutes to that gate deliberately to reproduce the former two-minute cutoff. CI/production rollout evidence is recorded separately when terminal.

During that same wait, an independent ordinary Python script sleeps beyond its deadline. The gate requires its original 120-second timeout error and confirmed cleanup, while the MCP call still succeeds. The two checks run concurrently using their existing separate capacities; this is not a second two-minute wait. The gate cancels and awaits the script on early failure before closing its task store.

The public API remains 24 and no client rebuild or hardware purchase is needed. Rollback restores the prior runner image and its former lifetime policy; task data and private lease checkpoints are preserved. Durable lease state across runner restart, general multi-host scheduling and other plan items are not closed by this lifetime change.

Published and deployed as main `67dd90c408862927c0907961b5f50defb88b3fce`,
release `20261028-155305-67dd90c`. CI run `40652916724`, job `122696998021`
completed successfully: 301 Dart, 58 runner and 28 deployment checks; the real
Docker JSON records `active_mcp_survives_code_timeout=true`,
`ordinary_script_deadline_enforced=true`, `active_mcp_observed_seconds=126`.
The image export/import gate reports `IMAGE_ROUNDTRIP_VERIFIED`.
Deployment completed health/data checks, resumed traffic and cleanup, then
reported public HTTPS 200 through Cloud Assistant, healthy current release and
one `latest-good` restore point with data. Client/device verification is separate
and was not performed. Complete P01–P14 remains open.
