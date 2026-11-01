# Root lifecycle follow-up (local work)

This batch follows verified scoped skill Hook release
`20261101-152921-4ce890b`. It is not deployed and does not close P11.

SessionStart and UserPromptSubmit are mapped before the root task Agent starts.
They use host-derived task/turn identities rather than invented tool refs.
Startup context survives later turns without repeating the startup effect.
Prompt submission is distinct for each original user turn and cached for its
approval resume. Blocking submission prevents target Agent/tool work. Current
authorization, source, cancellation and workflow checks apply to cached results.

The durable successful-verdict/unknown-effect logic is shared with skill once
handlers through PluginHookEventJournal, preserving existing private skill keys
and record fields. A pending original effect cannot be replayed by a new turn.
Known root events now use catalog profile 3; refresh reads the same immutable
source and preserves other component types. Skill-only lifecycle support is not
inferred from a root event mapping.

Local checks passed: 18 catalog/lifecycle/journal/skill state tests and 3 actual
SDK scenarios (context injection, approval resume with two total Hook executions,
and prompt denial with no target child/model/tool work). The Windows test worker
now decodes its JSON wire as UTF-8 explicitly; this fixed its Chinese prompt
parsing without changing source payload or weakening assertions.

The real-container mixed gate is extended from 14 to 16 code jobs and from 9 to
11 Hook successes, adding startup and prompt context. Existing private skill,
artifact, child session and immutable-source assertions remain. This version of
the gate has not yet run.

Complete targeted regression passed 114 tests, including old Hook/Agent/fork and
import cases. Final static analysis passed. Stop/async dispatch, container
acceptance, main synchronization and standard deployment remain pending.
Additional external SDK/account requirements
of the pinned security-guidance stress sample are distinct from event dispatch;
no provider credential is passed into a sandbox. Necessary Apps/extensions and
representative cross-entry acceptance remain open. No paid image service called.
Client 未执行验证，待用户真机验证。
