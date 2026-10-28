# Live MCP catalog recovery and effect identity

The original runtime discovered a connector once per preparation. The SDK could
invalidate its own cache on list-change notifications, but the application's
separate directory stayed unchanged. Small catalogs had no gateway to tools
added later. Duplicate names could throw after the per-connector discovery
catch, aborting preparation of other healthy connectors.

Complete page reads now validate the actual tools array, names, schemas and
opaque string cursors. A failed continuation, repeated cursor or duplicate name
discards that whole partial snapshot and restarts once from the first page.
Persistent instability fails the connector; malformed shapes are never silently
interpreted as an empty/partial success. Existing 100-page, 20-second-per-page
and 16-MB snapshot budgets stay in force. No tools/call request is retried here.

An application-owned live directory receives SDK tools/list_changed events for
remote and isolated connections. A notification during discovery invalidates
the read; only a complete stable-generation snapshot can be published. Failed
refreshes stay stale and concurrent refreshes share the same in-flight read.
Catalog search forces a current read. Invocation resolves the current tool,
validates its current input schema, and re-reads/checks its canonical definition
before confirmation or submission. Changes/failures produce explicit structured
results and lifecycle failure/skip events, allowing another catalog read without
submitting the target action. Permissions still depend on deployment-reviewed
effects, exact user actions, connection authority and the current schema.

Small connectors retain native aliases and gain a separate local directory
gateway. Large connectors retain their existing gateway aliases. New local
gateway aliases cannot collide with native tools named search_tools/call_tool.
This makes newly added tools discoverable in the same task and provides a way
to submit new parameters even if the model's initial native schema is old.
Gateway metadata identifies it as a local directory entry, not a service tool.

External effect journaling now uses the real connection/tool/arguments/request
identity, independently of native versus gateway aliases and schema refresh.
Successful repeat calls reuse the original result; an unknown result blocks
replay through another alias. Reads and isolated workspace operations stay
fresh. Current approvals retain their original canonical action hash format.
Existing exact legacy alias journals are consulted without copying them or
charging the budget again. For older uncertain gateway journals whose original
parameters cannot be recovered from their hashes, saved action bindings identify
the connector's old uncertain call and block a new external submission in that
request until it is checked or the human explicitly updates the task. Completed
unrelated legacy actions neither block nor substitute a new effect. Read tools
remain usable. This is preservation of unresolved old evidence, not a new
blanket confirmation rule for current actions.

An unknown external result is now reported as external_result_unknown with
retryable=false, rather than a misleading token/service error. Read failures
can be retried; operations rejected before submission say not_submitted. Tool
budget exhaustion is propagated instead of converted into an ordinary service
failure. No client API/UI contract or persisted product schema is changed.

References checked 2026-10-28: the official MCP
[2025-11-25 tools specification](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/docs/specification/2025-11-25/server/tools.mdx)
for pagination and list-change behavior, and the installed
[Genkit MCP 1.0.0](https://pub.dev/packages/genkit_mcp/versions/1.0.0) public
notification handler/listTools API. SDK implementation was inspected locally
without editing the dependency; its package license is Apache-2.0. The MCP
[repository license](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/LICENSE)
currently describes the Apache-2.0 transition, retained MIT contributions, and
CC-BY-4.0 for non-specification documentation. These are protocol/API references;
no upstream source or fixture was copied. Tests use original synthetic servers.

Focused validation: 17 initial directory/connection checks pass. Twenty-two
subsequent directory/actual Genkit MCP checks pass, including a 121st tool added
after startup, current-schema enforcement and one approved effect reached by
both aliases. The strengthened unknown-result/legacy checks are recorded when
terminal; full regression, exact-commit Docker CI and deployment remain pending.
No paid provider or image service is called. This addresses P05/P13 catalog and
alias defects; durable runner restart/RPC/input snapshots, remaining component
protocols and real client acceptance remain in the original full plan.

Final local checks: the broad run passes 340 tests and exposes one pre-existing
pagination fixture without inputSchema. Both fixture tools now carry an object
schema; validation is not relaxed. The corrected pagination, legacy operation
and all MCP-loop checks pass 32 tests with analyzer clean. A separate native
tool named call_tool passes through the real Genkit registry without colliding
with the local gateway. A separate alias-repeat rerun sends the same two
parameters in opposite map orders and confirms one actual effect, one approval
and one budget charge. External journals use the canonical action identity for
both their slot and argument digest. Full exact-commit CI remains the rollout
gate; the earlier broad run is not recorded as an all-green final run.
