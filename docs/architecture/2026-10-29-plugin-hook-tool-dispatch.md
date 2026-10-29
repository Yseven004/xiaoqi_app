# Root plugin hooks: tool-event dispatch

P11 implementation increment, following
[the execution foundation](2026-10-29-plugin-hook-execution-foundation.md).
This document supersedes that foundation's unconnected-runtime status. It does
not close P11 or the P01–P14 plan.

## Runtime behavior

Capability inspection now reports hook handlers independently. Command handlers
for PreToolUse, PostToolUse and PostToolUseFailure have **partial** status.
Unmapped events, handler types and malformed declarations remain separate
unsupported components. A healthy command/skill/Agent/MCP component does not
become unsupported because an auxiliary hook is unmapped.

Old installed versions refresh hook metadata from their pinned immutable
artifact; they do not download, reinstall or switch versions. Display-name
changes do not change source bindings. Tenant ownership, current enabled state
and the original artifact/component remain authoritative. Hook preparation
reuses a dependency preparation already done for the same component root during
that import; multiple handlers do not repeat the same preparation.

Tool middleware is installed on the parent Agent and delegated plugin Agents.
Hooks activate for selected plugin versions and sources actually loaded during
the task. Merely discovering another enabled plugin does not execute its hooks.
Explicit exclusions and withdrawn selection requirements remain in force.
Matching-source checks stay live through native tool submission. Selector
metadata remains readable after withdrawal so an unrelated, unmatched handler
cannot block healthy sibling work. Plain literal selectors/alternatives avoid
starting an isolated job when they cannot match. Real regexes still use the
bounded isolated worker.

The initial canonical tool mappings are Write/file_path/content for task-file
creation, Read/file_path for task-text reads, Bash/command for execute_shell,
and mcp__connection__tool with real arguments for direct/gateway MCP calls.
Other native tools retain their host names until their genuine source-tool
semantics are mapped. Rewrites preserve the same registered host tool and MCP
gateway target, then validate the current host and target schemas. They never
mutate the original SDK request used for restart/approval correlation. Hook
arguments and stdout remain data, and hook `allow` never supplies a user grant.

For MCP `ask`, the existing exact-action confirmation card is reused. The
rewritten parameters determine the action hash; approval is checked again before
submission. An exact prior approval is reused and denial is preserved. An SDK
interrupt triggers neither a successful nor a failed post event. On resume the
original hook operation/result is reused, after which the native tool processes
the original confirmation normally. No new card type or API contract is added.

Successful and failed native responses fire their respective post events.
Post context is attached to model-visible tool output. Output replacement
changes what the model sees, not the completed effect or stored artifact.
Replacement drops old multipart content; legacy updatedMCPToolOutput applies
only to MCP tools. A source stop prevents the current action and subsequent
model/tool processing in this Agent turn.

## Evidence and release status

Local checks completed before CI:

- Full Dart static analysis passes.
- 64 focused parser/protocol/runner/catalog/middleware/import/chain tests pass.
- The existing 17 real-runtime Agent scenarios pass, including four new root
  hook cases. After the final matching-granularity changes, the four root cases
  pass again, including one original pre-hook and one post-hook across MCP
  approval/resume, two total code-budget charges, and no pre-approval effect.
- The bridge in these Agent tests is a trusted fake Python worker. They exercise
  the production SDK/runtime/journal, but do not claim Docker command execution.

The CI stdio gate now adds a real Node/Bash launcher probe and root command hooks
to the existing mixed-MCP/Shell Agent loop. The pre-hook must modify the actual
Shell command to produce an exact fourth artifact, the post-hook must observe
that result, two hook executions plus the two existing code executions must
charge exactly four attempts, and protocol stdout must not become an artifact.
CI/deployment results are to be recorded after they actually finish; these
statements define the gate, not a passing result.

## Still open

This increment does not implement all lifecycle events, async/once/conditional
or direct-argv commands, HTTP/prompt/agent handlers, deferred scheduling, a
read-only command sandbox, every native source-tool alias, or true in-place
mutation of another workspace/MCP volume. An unmapped ask/defer or matching
command hook in a read-only child stops that target with an explicit mapping
error; it does not silently grant permissions or disable unrelated tools.
Task termination presentation, exceptional failure context, complete API-restart
hook-verdict recovery acceptance and full client/device acceptance also remain
open. Root hook support therefore stays partial until these required mappings
and acceptance cases are complete. apps/extensions and the other plan items are
not replaced by this batch.
