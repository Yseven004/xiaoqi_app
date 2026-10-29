# P11 Agent skill preloading — implemented locally, not released

Original gap: PluginAgentPolicy rejected any nonempty `skills` list.
SelectedSkills skipped an explicitly selected Agent component and discovery excluded
that pinned parent; therefore a plugin's sibling skills are not necessarily in the
staged turn catalog. Merely removing the policy rejection would silently drop the
declared instructions and leave resource/script tools unable to resolve the skill.

Implemented within the existing approved P11 scope:

1. Resolves declared names against the current tenant's enabled skills, preferring
   the Agent's own pinned plugin/version. Qualified plugin names must match their
   declared manifest namespace. Never pick an arbitrary same-named installation,
   different tenant or newer plugin version. Ambiguous/missing bindings return a
   useful recovery result without starting the child.
2. Includes full SKILL.md and the exact resource listing in the child's initial
   context, not just a catalog description. Bind the resolved immutable source and
   content fingerprint into private child-session resume identity.
3. Registers the resolved skills in the turn-local resource/script allow-list and
   staging directory. Preserve `disable-model-invocation`, tool restrictions,
   cancellation, token/turn budgets and the existing network/effect authorization.
   Loading instructions cannot authorize an external action.
4. Validates every bound source at model/tool effect checkpoints and approval
   resume. Disabled, removed or changed definitions stop use; a sibling update
   cannot silently replace the originally selected version.
5. Seven binding tests pass for the pinned older source, resource identity, frozen
   bindings, stable manifest namespaces, collisions, missing/user-only skills and
   disabled sources. The real Genkit child reads a preloaded sibling resource and
   writes its report. A second real child invokes a preloaded skill script, pauses
   for temporary network approval, rebuilds the runtime and resumes once; no
   script runs before approval and the network grant is removed after completion.
   Existing plan/dontAsk/denial/nested-agent cases remain passing. Twenty focused
   tests and full static analysis pass. Full suite, CI and deployment are pending.

This batch does not implement Agent mcpServers/hooks/memory/isolation/background,
nor close P11 or the overall P01–P14 goal. It adds no new dependency or service and
does not widen parent tool access or original user authorization.

Source checks also run before each MCP send/control retry in the existing async
authority zone. A source withdrawn after the first accepted/lost-ack submission
cannot authorize another HTTP submission or a later queued message. Cleanup and
result/file recovery remain available. The focused transport regression simulates
source withdrawal with a transient response, rather than only an explicit denial.

Fixed-source local acceptance passes all 26 focused cases (seven binding, three
policy, eleven actual Genkit runtime scenarios and five transport cases), with
full static analysis reporting no issues. Earlier full local runs are not final
acceptance: the parallel run had a 30-second child-process timeout and the serial
run overlapped subsequent source edits. Full-suite acceptance is required on the
immutable CI commit before deployment. No failed local run is counted as passing.

Reference inspected 2026-10-29:
[Anthropic subagent frontmatter and skill loading](https://code.claude.com/docs/en/sub-agents#preload-skills-into-subagents).
The documented source profile injects complete skill instructions at child
startup. Its missing-skill warning behavior is a reference, not permission to
silently claim this app has fulfilled a required skill-dependent task. No upstream
implementation is copied and no new dependency is proposed.
