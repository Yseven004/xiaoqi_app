# Cross-entry evidence review

This is an inventory, not final P01–P14 closure. Existing tests below were part
of successful exact-main CI `41269309017` and release
`20261101-113206-281cd51`. Their assertions were reread on 2026-11-01; that
does not turn a local fixture into a live account or device test.

| Boundary | Existing evidence to preserve | Still separate |
| --- | --- | --- |
| Task scope across entries | `remote_agent_api_test.dart`: ordinary followups keep capabilities, removal and branches isolate scope | Selected real plugin entry combinations |
| Network off versus reauthorization | API tests capture off revision before concurrent on; runner tests reject old/rebound/expired tokens, kill only owned task proxies and preserve newer revisions | Ending one live invocation while another authorized invocation continues |
| Live network revocation | `bin/support/network_lifecycle_gate.dart`: a running proxy loses connectivity; immediate reauthorization works; delayed off cannot revoke the new revision; cleanup is confirmed | Shared-invocation composition rather than another rewrite of this gate |
| Pre-submit authority | `code_execution_service_test.dart`: withdrawal during token lookup or bridge startup never submits IO; unrelated request identity cannot submit | Apply to remaining selected protocol adapters as they are implemented |
| Catalog discovery | `mcp_tool_directory_test.dart`: 240 tools across pages, interrupted paging restarts a clean snapshot, a mid-discovery notification cannot publish mixed catalogs, concurrent recovery shares one complete catalog | Actual connection health changes during a task and cross-entry discovery refresh |
| Resource normalization | `capability_chain_test.dart`: full 100000-byte media is retained, task-owned and deduplicated; inline normalization stays under 3000 characters | Resource read entry and oversized/forbidden URI checks are not established by normalization alone |
| API restart and unknown effects | `mcp_api_rpc_recovery_test.dart`: API death after submission, with/without cancellation, preserves one effect and budget; executor tests recover original files after store reopen and preserve late recovered success | Older unbound file recovery and all promised pending-RPC timings |
| Budget and cancellation | Executor tests share atomic code/query budgets, retain attempts over resume and failure; turn-scope tests block new calls after cancel or steering | Parent/child/Hook/MCP mixed concurrency and provider failure combinations |

Dynamic command context adds seven local authority/recovery tests in
`plugin_command_context_execution_test.dart`: resume identity, private profile,
unknown-effect no replay, source withdrawal before/after IO, withdrawal or cancel
before cached reuse, and answer-only denial. These were independently run and
passed after `7cec098` was frozen for CI; they are not yet claimed as part of
that commit's CI artifact.

The next protocol work must carry these same boundaries through scoped skill
Hooks and required lifecycle/async handlers. Neither disappearing compatibility
warnings nor a healthy deployment closes missing representative acceptance.
Client 未执行验证，待用户真机验证。
