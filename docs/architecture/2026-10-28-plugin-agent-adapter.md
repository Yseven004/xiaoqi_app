# Plugin agent adapter — draft, not a released capability

The importer/task runtime do not yet register agents as supported. This draft
adds source profiles and the private SDK session core, not a completed P11.

Genkit 1.0.0 agents middleware cannot propagate resumable child interrupts.
The core uses the actual SDK Agent/chat/session API instead, preserving child
state and original ToolRequestParts in private server documents. Scope,
invocation, definition and task bind restoration. Client/model payloads cannot
supply child messages. Existing approval data is passed through existing cards.

The SDK requires all pending requests on resume. Only the selected request gets
the human decision; undecided requests re-enter their approval guard without a
grant. Completed pendingOutput requests are excluded, even though Genkit 1.0.0
retains their old interrupt marker. This behavior is verified against the locked
SDK without modifying the dependency. Runtime tools must approve before effects.

One durable delegation reservation survives resumes. Child HTTP requests and
tools share existing task budgets. Scope changes/cancellation block execution.
Unconfirmed active child state is preserved without restarting its task. A child
session ending normally is not proof of the parent's delivery contract: actual
parent tool/artifact evidence remains required.

The parser validates YAML/name/description, inherited versus explicit-empty
tools, allow/deny lists, model/turn count and behavioral field types. It preserves
host metadata for policy mapping, not authority. Default/custom source locations
stay inside the package; malformed files do not hide healthy siblings. Plugin
root substitution is literal. The shared immutable registry extraction preserves
existing command aliases, fingerprints and tenant/source/version validation.

References read 2026-10-28: installed Genkit/genkit_middleware 1.0.0 (Apache-2.0),
the project's developing-genkit-dart agents/HITL/multi-agent references, the
[official agent example](https://github.com/anthropics/claude-plugins-official/blob/main/plugins/plugin-dev/agents/agent-creator.md)
and [plugin-dev guide](https://github.com/anthropics/claude-code/blob/main/plugins/plugin-dev/README.md).
Upstream text/source is not copied; fixtures/prompts are original. Explicit model
names are preserved rather than silently replaced by a different provider.

Local evidence: 25 parser/command/session/budget/reconciliation tests and analyzer
pass. Session tests run the actual SDK/OpenAI adapter with a fake HTTP client
wrapped by TaskModelClient: two consecutive approvals across database/registry
rebuild, one effect each, denial, task stop, scope/version/task mismatch, unknown
state, one reservation and provider-budget exhaustion without effect replay.

Required next steps before publication:

1. Register/import/reindex agent components from the same immutable package and
   instantiate the shared registry with agent type; syntax alone is not readiness.
2. Add directory/delegation/resource runtime entry points and current-scope
   completion/active-capability/source/script bindings. Original human text,
   HTTP client, cancellation and budgets remain owned by the parent task.
3. Install child model/tool middleware that checks scope and live source
   revocation, filters parent-authorized tools and maps permission modes. Do not
   map Write to arbitrary Shell/Python; use narrow scoped material/artifact IO.
   Unavailable explicit models and host fields need per-agent dependency states.
4. Use server-owned invocation ancestry plus original SDK refs; resume exact
   child requests. Child text stays out of public final streaming; child tools
   must not rewrite the parent's delivery plan. Keep parent artifact validation.
5. Verify real parent/child loops, budgets, approval, cancellation, revocation,
   resource/script bindings and recovery, then full CI and standard deployment.

Hooks/apps/extensions and remaining P01–P14 requirements retain their full scope.
