# Plugin hook execution adapter — work in progress

Status: parser, output protocol and isolated command adapter implemented and
checked locally. **Not connected to capability import or Agent event dispatch.**
Installed root hooks still retain their existing unsupported status. This is
not completion of P11 or the complete permissions plan.

## Source protocol and mapping

Reference: [Claude Code hooks reference](https://code.claude.com/docs/en/hooks),
retrieved 2026-10-29. This is a protocol reference, not copied implementation or
a claim to support every event/handler in the changing source host. No upstream
source code or new dependency is incorporated.

`PluginHooks` merges the default hooks/hooks.json and declared file/inline maps
in source order. It keeps event, matcher, JSON pointer and handler configuration
separate. Individual malformed declarations produce local issues; healthy
siblings remain inspectable. Configuration is deeply immutable and bounded to
128 KiB per document. Source regexes are retained as data on the API host.

`PluginHookOutput` maps structured control, exit codes and failure policy.
Pre-tool denial prevents a pending action; post-tool feedback never undoes an
already executed effect. Exit 2 cannot be undone by allowing, malformed or
oversized JSON. PermissionRequest uses its explicit JSON verdict rather than
treating exit 2 as denial. Updated arguments and output stay separate from the
host's authorization. `allow` is advisory: it cannot grant another recipient,
domain, file, capability or task. Rewritten inputs must be schema-validated and
authorized again by the future dispatcher. Stop/loop control and tool-output
replacement remain explicit fields rather than executable instructions.

`PluginHookCommand` produces a Node launcher for the existing isolated code
runner. Handler commands run in Bash inside that sandbox. Hook input is
JSON-encoded stdin with a final newline; it is never interpolated into the shell
command. Only the sandbox environment is inherited, with plugin/project roots
mapped to its own directories. Regex evaluation uses a worker terminated after
500 ms. Command output is bounded to 128 KiB and command process groups are
stopped on timeout or overflow. The normal code budget remains 120 seconds;
the launcher leaves collection time by capping its command timer at 115 seconds.
Cancellation and container cleanup remain the existing runner's responsibility.

`PluginHookRunner` invokes that launcher through DockerCodeExecutionService and
ToolExecution.authorizedCode. It binds immutable source identity, event identity,
configuration and input to the original operation. A confirmed original result
is reused; changed arguments or unknown original effects cannot resubmit it.
The original code execution journal, scope-operation binding, resource budget
and cancellation pipeline are reused. No network domains are added. Source
availability and task authority are checked before submission and after result
collection, including cached results. Answer-only scopes do not start workflow
hooks. The sourceFiles callback must validate source state without recursively
entering ToolExecution checks.

## Verified evidence

- 22 focused Dart tests pass: six parser, ten output-protocol and six execution
  adapter tests. Execution adapter tests use a fake executor to exercise event
  identity, unknown results, source withdrawal, cancellation and task scope;
  they do not prove Docker execution or real API restart recovery for hooks.
- The same launcher executes six trusted fixtures with real local Node/Bash:
  Unicode/Shell syntax preserved as JSON input, exit 2, unmatched selector,
  command timeout, expensive regex timeout and a real JSON denial.
- Native probe: `dart run tool/verify_plugin_hook_commands.dart` reports
  HOOK_COMMAND_NATIVE_VERIFIED cases=6 bytes=33962. This CLI only runs checked-in
  test fixtures on the development host. It is not an imported-plugin launcher.
- Targeted analysis of all nine new Dart files passes without issues.

The reusable real-sandbox helper is in bin/support/plugin_hook_gate.dart, but is
not yet called by verify_stdio_runtime.dart. No Linux Docker, CI, production
hook-dispatch, hook API-restart or client/device acceptance is claimed here.

## Remaining integration and acceptance

1. Import independent hook component states and refresh old installed metadata
   from the same immutable bytes. Do not mark incomplete mappings supported.
2. Bind active plugin hooks to the actual selected/loaded source and original
   SDK event reference; wire pre/post tool, lifecycle, stop and failure events.
   Required event input fields and tool names must map to real host behavior.
3. Revalidate rewritten inputs through actual tool schema/current authorization.
   Map ask/defer/stop/continue/output replacement without new implicit grants or
   repeated approvals. Hook permission allows never bypass task authority.
4. Wire and run the actual sandbox helper; prove cancellation, source withdrawal,
   original invocation recovery and one budget charge through real execution.
   Recover a hook verdict as a verdict, rather than merely showing recovered
   code output in model history.
5. Map required async/once/conditional/direct-argv, HTTP, prompt and agent handlers
   and remaining necessary events. The current adapter explicitly rejects these
   incomplete command modes. Other component handlers must not be silently
   downgraded into Bash or granted API-host execution.
6. File-modifying hooks need genuine workspace mutation/artifact semantics:
   modifying an isolated input copy must not masquerade as modifying its source
   or another live MCP volume. Preserve healthy sibling components and errors.

No runtime activation, contract change, client rebuild or deployment is needed
for this unreachable foundation. Bundle its dispatch integration and real gate
with the subsequent coherent server release. The full P01–P14 scope remains open.
