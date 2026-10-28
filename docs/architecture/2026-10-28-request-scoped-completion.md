# P03/P13 completion conditions follow the current user request

The runtime reset a task plan when a user corrected the task, but appended the
original unavailable-skill/plugin/MCP lists to every later completion check. It
also forced originally selected skills into new plans and implicitly attached
the old selected skill to ordinary code execution. A withdrawn extension could
therefore keep blocking an unrelated text/code request.

`ScopeRequirements` now identifies the original selections, pinned skill
components, command selections, MCP connections and unavailable dependencies.
Failures have stable component identities independent of error wording; pinned
versions remain distinct. Parent selection withdrawal covers children, while a
shared connector stays required by an unwithdrawn parent. A missing parent never
silently removes an error. These are completion conditions, not tool grants.

The separate no-tool intent router receives only the latest human instruction,
trusted task-local human steering history and a server-owned requirement catalog.
Names/descriptions/failures are data, not instructions. It can return
`withdrawn_requirement_ids` when the user withdraws a component or replaces the
task with one which no longer needs it. Tool failures, model plans or a desire to
declare success cannot withdraw conditions. Only catalog IDs are accepted;
unknown IDs are discarded, and omission means no withdrawal. The current scope
persists these IDs and retains them across a terse follow-up unless the user
reintroduces the requirement. No remote annotation or tool output edits them.

Steering clears the prior plan and current loading/activation evidence. Resumed
explicit-skill loading and required-plan validation consult the current scope.
Implicit skill fallback for ordinary code/search uses current required choices,
so a withdrawn former selection cannot demand `use_skill` or stage its files into
an unrelated call. Explicitly addressing an available capability still uses the
same ownership/loading/effect checks. Tool discovery remains independent of this
completion metadata; external operations still require exact action permission.

An early correction also exposed a command-load restoration bug: checking old
loading evidence threw before the steering middleware could process the new
instruction. It now restores no old command load state while a correction is
pending, then lets the normal scope/cancellation checks handle subsequent tools.
An unresolved intent now uses the existing clarification scope, including during
steering, instead of leaving workspace tools enabled under an answer scope.

Late corrections have a defined path too. If steering changes scope when the
final answer generation starts, its chunks are held until validation. A new
workflow, cancellation/clarification or unmet current requirement discards that
answer and exits the old preparation through its normal cleanup. The outer
task loop then prepares the new human request. It clears prior SDK respond/
restart inputs, retains completed results/history/artifacts, and remains inside
the same task-wide model budget and cancellation boundary. It does not software-
replay an old tool request. Pure wording corrections whose current conditions
are satisfied can finish directly, with current activation provenance. A held,
discarded provider generation is still counted, not hidden from the budget.

Implementation stays within the previously approved Genkit 1.0.0 middleware,
session/state and per-operation policy design documented in the permissions
audit and implementation plan; no dependencies or protocol library were added.
This is private task-state metadata, not a new public API or client workflow.
API remains 24. Standard image rollback can retain additional scope fields;
the deployment's single data restore point preserves the pre-activation state.
No source packages, credentials, old operation outcomes or completed artifacts
are rewritten by requirement withdrawal.

Validation: an initial complete 324-test regression passes. Five subsequent
actual Genkit/mock-provider loops cover withdrawing unavailable extensions,
keeping a genuinely required missing plugin incomplete, preserving withdrawal
through a terse second correction, ordinary code after withdrawal with no old
skill files, and a late answer-stage code request automatically re-entering
preparation. The latter checks that the stale answer never reaches legacy text
streaming and code executes once. All fixture provider POSTs equal the persisted
task counter, including classifiers and discarded generations. Unit checks cover
parent/shared requirements, changed errors, unknown-ID rejection and scope
serialization. Final broad regression/analyzer and rollout are recorded when
terminal; no paid image or real external-send call is made.

Final local validation: all 326 Dart tests pass and analyzer reports no issues.
The initial ordinary-code assertion used scope-operation records, which exclude
the separately budgeted runner execution; it now checks the actual persisted
code execution count and the returned worker output. The late-correction case
checks one code execution, no stale final text, and unchanged provider-count
accounting. CI, server deployment and real-client effectiveness remain pending.

This batch does not close all P03/P13: live connector re-discovery after health
changes, original pending RPC/input snapshots, wider restart recovery and the
remaining protocol/client acceptance matrix retain their original scope. New
task completion must still be demonstrated with actual tool results, and real
provider interpretation/client-device behavior is separate from local fixtures.

Deployment evidence: main a982aef4b7b86dd9bfe464a0528ac3cc6a164aa0,
GitHub Actions 40692493105/job 122830632421 completed successfully. CI passes
326 Dart tests, 60 runner tests and 28 deployment tests, the actual Docker stdio
and command/script loop gates, and IMAGE_ROUNDTRIP_VERIFIED. Standard non-image
deployment completed with controller exit 0 as 20261028-210026-a982aef.
The service is healthy, public HTTPS returns 200 through the same-endpoint
Cloud Assistant verification, and latest-good plus its data restore point are
present. Deployment log: primary checkout .codex-artifacts/deploy/
20261028-210026-a982aef.log. This records server deployment and verification;
real client/device effectiveness remains unverified. Paid image cases remain
explicitly deferred by the user.
