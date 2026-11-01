# Dynamic command context acceptance

## Scope and source

Adds isolated preprocessing of Markdown `!`backtick shell context blocks before
ordinary command rendering or private fork delegation. This follows the pinned
official commit-commands sample recorded in
`2026-11-01-plugin-protocol-sources.md`; it does not claim that a real Git
repository or every command in that sample has been exercised.

Installed command metadata is reindexed from unchanged source bytes under parser
profile 3. The selected DeepSeek V4.1 Flash mapping remains unchanged.

## Boundaries

- Commands execute through the existing sandbox and durable authorized-code
  operation, bound to immutable source and original tool request identity.
- Cancellation, workflow stage, current permission and source are checked before
  submission and after results. Recovery reuses the recorded result rather than
  replaying shell effects.
- At most 16 blocks run sequentially within a 110-second launcher deadline and
  128-KiB aggregate output bound. A failure stops later blocks. Child process
  groups are terminated after each block. Invalid envelopes never become prompts.
- Arguments are literal environment/argv data. Rendered outputs and arguments
  are inserted once and cannot introduce a second template or command execution.
- The trusted JavaScript launcher uses a dedicated execution profile, with no
  external network grant. Existing task materials and immutable plugin files
  remain sandbox inputs; server environment and credentials are not inputs.
- Read-only fork preprocessing can compute in its private sandbox, but neither
  immediate nor recovered output files are persisted to the task. This retains
  the existing read-only Hook policy.
- Code and model usage retain the task's cumulative budgets. Preparation does
  not itself count as successful command delivery.

## Verification status

Local targeted checks passed: 9 parser/context tests including native Node/Bash
literal argument and failure-stop execution; 4 SDK dynamic-fork cases covering
normal, read-only, approval-resume and denial; 34 runner Python tests. Complete
local parser/import/policy/Agent/code-executor/Hook regression passed 109 tests.
Seven additional authority/recovery checks passed: original result reuse,
argument identity conflict, private read-only profile, unknown-effect no replay,
withdrawal before and after execution, cached-result withdrawal/cancellation,
and answer-only workflow denial. These are local executor-boundary tests, not
substitutes for real-container or live-service results.

The real-container gate now requires expanded context in both ordinary and
read-only fork commands. Mixed composition expects 11 actual code jobs (previous
9 plus two preprocessors), 6 Hook successes, two private child sessions and
exactly four original artifacts. A file written by read-only preprocessing must
not be exported. Immutable SKILL bytes must remain unchanged.

All 5 ordinary-command SDK compatibility cases also passed; `dart analyze`
reported no issues and `git diff --check` passed. Exact-main CI `41272581892`
passed 489 Dart tests (one native-launcher skip in the build stage), 95 runner,
30 deployment, 2 bridge and 2 image tests. The actual launcher passed the full
real-container gate, including both new dynamic-context assertions and image
export/import roundtrip. Standard deployment `20261101-121830-7cec098` exited 0;
runtime probe, health/data, traffic resumption, cleanup, public HTTPS 200 and API
24 verification passed. One latest-good restore point and its data remain.
This batch is server deployed and verified. See
`evidence/2026-11-01-dynamic-command-release.json`.
Client 未执行验证，待用户真机验证。
