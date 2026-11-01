# Root lifecycle follow-up (local checks complete; release pending)

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

Stop now runs at the end of the task Agent's tool/work phase, before the separate
tool-free final presentation. An explicit veto continues the same authorized
chat; `stop_hook_active` is persisted per original user request and each original
event retains its original flag on recovery. A crash/timeout is not automatically
treated as a veto. This phase mapping does not inspect final display wording.

Root and skill command Hooks can run in the task-owned background queue. The
original action proceeds without waiting for the command. The host joins pending
checks before completing the task turn, rather than detaching effects beyond
the task lifetime. Every command keeps Xiaoqi's 115-second launcher ceiling and
existing cumulative task/model/code budgets; upstream unbounded background
timeout behavior is deliberately not imported. Completed feedback and original
pending descriptors persist in private storage; original code operation recovery
retains the existing unknown-effect no-replay policy. Acknowledgment occurs only
after the task processes feedback. Skills' concurrent once checks are serialized
within their original source/session binding.

Background verdicts cannot veto/rewrite already performed actions or grant
permissions. `asyncRewake` only returns a reminder on exit 2, stderr first with
stdout fallback. Background `onFailure:block` cannot block the original action.
Source/contract/cancellation are rechecked before running and before feedback.

The `if` permission-rule spawn filter is evaluated in the bounded matcher worker.
Simple Bash subcommands/leading assignments and file globs are supported; shell
constructs whose effects cannot be resolved statically run the check
conservatively. This is a spawn filter, never a permission enforcement mechanism.
Only tool events evaluate it; lifecycle events with `if` do not spawn a command.

The real-container mixed gate now expects 18 code jobs / 13 Hook successes / 5
verified artifacts, adding startup/prompt and async Stop. Stop requires an actual
review.txt, then a later isolated check rereads it. Existing private skill,
child session and immutable-source assertions remain. Gate execution is pending
exact-main CI and must not be called passed before that job succeeds.

Earlier targeted regression passed 114 tests. The expanded full local suite
passed 531 tests (`%TEMP%/xiaoqi-full-hook-regression.log`). Final strengthening
then passed 26 targeted queue/lifecycle/runner/condition checks and static
analysis (`xiaoqi-hook-final-tests.log`, `xiaoqi-all-analyze-final.log`);
final SDK rerun/CI/deployment status must be recorded separately. Five lifecycle
SDK scenarios already passed context, approval, denial, Stop repair and async
Stop repair before that strengthening. Real Node condition tests passed.
Additional external SDK/account requirements
of the pinned security-guidance stress sample are distinct from event dispatch;
no provider credential is passed into a sandbox. Necessary Apps/extensions and
representative cross-entry acceptance remain open. No paid image service called.
Client 未执行验证，待用户真机验证。
