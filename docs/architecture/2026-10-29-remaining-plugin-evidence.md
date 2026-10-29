# Remaining plugin adapter evidence (not implementation acceptance)

Checked 2026-10-29 against the current source. This records concrete remaining
requirements; it does not extend the agreed scope to generic device control or
claim every third-party host protocol is interchangeable.

## Confirmed gaps

`capability_import_service.dart` still reports hooks/apps as unsupported and
client extensions as unexecuted. `plugin_agent_policy.dart` rejects nonempty
mcpServers/hooks/memory/isolation and background requests without host mapping.
Removing these diagnostics would not implement their behavior. Commands and
skill-preloaded child agents already have runtime adapters and must retain their
source, task authorization and shared-budget checks when these gaps are filled.

The official security-guidance plugin is a concrete hook reference: version
2.0.17 was observed, with command handlers for task/session and tool events and
asynchronous review. Its documented portable output makes host-specific output
differences explicit. Reference only; no upstream code was copied or installed.
Repository license observed: Apache-2.0. It requires further version-pinned
inspection before becoming an executable acceptance fixture. Its external model
calls are not authorized by importing a plugin or by this reference research.

Sources checked:
- https://code.claude.com/docs/en/plugins-reference
- https://code.claude.com/docs/en/hooks
- https://github.com/anthropics/claude-plugins-official/blob/main/plugins/security-guidance/.claude-plugin/plugin.json
- https://github.com/anthropics/claude-plugins-official/blob/main/plugins/security-guidance/hooks/hooks.json
- https://github.com/anthropics/claude-plugins-official/blob/main/plugins/security-guidance/README.md
- https://github.com/anthropics/claude-plugins-official/blob/main/LICENSE

Required adapter acceptance: parse real declarations with independent component
status; bind each triggered handler to its immutable source and actual task
event; supply the documented event input; consume its output; enforce parent
authorization and cancellation; persist invocation identity before any effect;
recover or report unknown results without replay. Test trigger matching,
denial, duplicate events, failures, source withdrawal and restart. Apps/extensions
also need the actual resource/message protocol and the agreed client presentation
and event return path, not an unsupported-message removal. New UI decisions stay
subject to the existing project design workflow.

## Existing behavior rechecked

The only production call of `DockerCodeExecutionService.disableNetwork` is the
explicit task network-controller entry. API handling invokes it for mode off.
`NetworkCallAuthorization.execute` and both Agent script execution paths do not
call it on individual execution completion. The suspected task-wide disconnect
on temporary script cleanup is therefore not present in the inspected code;
no speculative fix is justified. Runner task-wide revocation remains necessary
for the explicit user off action. Cross-source real-container verification stays
an acceptance item rather than being claimed from this call-graph inspection.

Large MCP catalogs already have production notification invalidation, complete
snapshot reload, schema recheck and a bounded search/call gateway. Existing real
Genkit scenarios include mcp-large and mcp-large-refresh; directory tests cover
expired cursors, duplicate names, failed refresh and concurrent reads. Do not
reimplement these paths because the broader plan is still open. Their production
code is distinct from the remaining connection-health and lifecycle acceptance.

## API restart result gap

`mcp_lease_recovery_test.dart` verifies API process death, original lease
termination, authenticated artifact recovery and no replacement process. It does
not verify recovery of a pending tool response. `recoverMcpLeases` currently
closes the original lease and records artifacts; `SandboxMcpTransport` keeps send
sequence and event cursor only in the live API object. Runner restart continuity
therefore cannot stand in for API restart result recovery.

Required proof: kill the API after one actual external-effect request reaches
the original MCP process but before its response is delivered; rebuild the API
against durable state; correlate and collect that original response once; do not
send the effect again, recreate the plugin process or consume its budget twice.
Persist operation/lease/RPC identity before submission and persist the correlated
result before acknowledging its event batch. Source withdrawal, authorization
revocation and task cancellation must still prevent new effects during recovery.
If the original result truly cannot be obtained, preserve files and report the
unknown outcome explicitly. This gap remains open; no API restart success is
claimed from the existing artifact-only recovery test.
