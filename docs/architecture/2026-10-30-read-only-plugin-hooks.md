# Command hooks in read-only delegated Agents

## Scope and semantics

The middleware previously rejected every matching command hook in a read-only
delegated Agent, including hooks that only calculate a verdict before a read.
It now passes `permission_mode: plan` and selects a private
`plugin_hook_read_only` execution profile. Original source/version checks,
event identity, command timeout, task execution charges and result recovery are
retained. The native target still passes through the delegated Agent's tool
policy; a hook cannot grant a write tool or widen its input authority.

Read-only means that hook execution cannot persist its writes to the task or
installed package. It may create or change temporary staged copies in its
isolated workspace, just as a compiler may require temporary files. This is
not a claim that the workspace filesystem is mounted read-only. No output files
are exported on normal completion, durable checkpoint or runner startup
recovery. Cleanup removes the temporary workspace. Hook protocol stdout still
returns the verdict and context through the bounded private channel.

The API service independently drops reported artifacts both on immediate
completion and after reopening its database and recovering the original
execution. The private profile is saved with that execution and on the owned
container label. Normal scripts and normal command hooks keep their existing
artifact behavior. Network domains are rejected before submission by the API
and runner. The profile preserves the ordinary 120-second computation deadline,
CPU/memory/process limits, network isolation and original budget accounting.

## Evidence and remaining checks

- Runner suite: 91 tests pass, including no export call/checkpoint artifacts,
  no network, private profile label and startup recovery of bounded protocol
  output without ephemeral files.
- Execution service and runner adapter focused tests passed. They cover the
  immediate no-export boundary and replay of the original verdict. Middleware's
  ten tests pass after adding the actual Read schema to its test validator.
- A real Python bridge test loses its initial result stream, reopens the task
  database, recovers original stdout and confirms no returned artifact becomes
  persistent and the invocation count stays one.
- Dart static analysis passes. The additional recovery test compiles and passes.
- The production Genkit parent/delegated-Agent integration scenario passes:
  a plan-mode child exposes Read without Write, both original Read hooks receive
  plan mode and the private read-only profile, the post hook observes the actual
  original file contents, the Agent completes and two hook executions are
  charged. Its isolated execution transport is a trusted Python fixture, not a
  real Docker run; the existing source-write/deny/invalid/approval cases remain
  separate regression checks.
- The real Docker hook gate now writes temporary output and mutates a staged
  source copy, verifies computation output and absence of task artifacts, and
  checks cleanup. This new gate has not run yet. A full delegated Agent/container
  read-only workflow remains to be verified; the SDK/fixture checks do not
  replace it.

The next mixed-plugin real Agent gate now delegates to an actual plan-mode
Agent with only Read. Its source Pre/Post hooks assert the plan payload and
actual MCP-produced file contents, deliberately write a temporary output and
mutate a staged skill copy. Acceptance still requires exactly the four original
deliverables, unchanged installed skill bytes, one completed child and seven
code executions: MCP startup, Shell, command script and four command hooks.
It rejects write/code tools in the child model request. Literal matcher
alternatives avoid charging isolated matcher jobs for unrelated tools. This
complete container workflow is added and statically checked but has not run;
the current in-flight release predates this gate extension.

No current deployment includes this change. Previous production service remains
in place while the prior exact-main build/deployment is active. This change
does not close other Hook lifecycle/async/once/protocol mapping requirements or
P01–P14 as a whole. No client change, paid provider or new hardware is required.
