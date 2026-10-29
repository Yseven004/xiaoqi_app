# Native tool result checkpoint before post-hooks

P11/P13 follow-up. The full plan remains open.

## Reproduced problem

The tool middleware previously called the native tool before starting its post
hook. If the latter failed, reconstructing middleware with the same SDK event
called the native tool again. A targeted regression run against primary main
66f89eb reproduces two effects where one was expected. This is a local behavioral
reproduction, separate from the Docker gate failure below.

PluginHookToolJournal now claims the original native event before invocation
and checkpoints its unmodified response before any post-hook. The claim binds
task/request identity, original SDK event, registered tool and effective input.
Input key order is canonicalized; changed values cannot reuse the event.

The private result blob includes output, multipart content and metadata. Its
size and SHA-256 are reserved in task metadata before the atomic blob write.
The intermediate result_pending state can recover the original blob if a
process dies before the ready marker. Neither the blob nor its protocol fields
are registered as user artifacts. Event count uses the existing task tool limit,
and retained native responses are bounded to 32 MiB per task. No extra operation
or code-budget charge is introduced by this metadata checkpoint.

An original permission interrupt is marked waiting and may re-enter the native
handler only through SDK resumed metadata. Native outcomes left running cannot
be automatically resubmitted through the same event or an identical target/input
under a replacement reference. Other targets are not globally disabled. A
confirmed result is read before post-hook work resumes. Source withdrawal,
current task scope and hook authorization checks still run on every attempt.

## Verified local evidence

- The old middleware regression fails with actual effects=2, expected=1.
- Updated middleware passes that regression with original effects=1.
- A real child Dart process is forcibly killed after a file effect/checkpoint,
  while its post event is pending. A second process reopens the same database
  and blob store, restores the original output, multipart text and metadata,
  and leaves the effect counter at one. This is native process-death evidence,
  not a claim that the full HTTP/production Agent restart path is accepted.
- Private-journal tests cover database reopen, input binding, canonical key
  order, original confirmation restart, missing/corrupt blob, intermediate
  checkpoint recovery and unknown-result replay protection.
- 73 focused local tests pass, four real-SDK root-hook scenarios pass again,
  and full Dart analysis passes. Native launcher verification now runs seven
  fixtures, including the exact Python pre-hook shared with the Docker gate.
- A forged cache pointer cannot read another tenant's blob, even when its
  checksum and declared size match that foreign blob.

Remaining recovery acceptance includes process death while a native operation
itself is still running: this journal deliberately reports an unconfirmed result
instead of resending it. Full reconciliation through all underlying operation
types still needs to be proven; this increment does not claim universal replay
or crash recovery.

## First Docker gate and next verification

CI 40894142924/job 123518542959 on main 66f89eb passes 446 Dart, 87 runner and
30 deployment checks. Existing real runner/API restart gates pass. The new
mixed-MCP/Shell hook Agent case then fails because its expected hook-generated
artifact is missing. The deployment controller exits 1 before activation;
production remains on 20261029-191909-6f2831d.

The original failure did not print per-hook diagnostics, so its precise cause
is not yet proven. Literal selectors now reuse their safely computed match
instead of unnecessarily starting a regex worker in the constrained container.
The gate now reports artifact names, code counts and bounded hook errors; its
required fixture hooks explicitly block on failure. The same Python script is
shared with native verification instead of only testing shell builtin fixtures.
A subsequent real Docker gate must establish whether the issue is resolved.
Do not describe it as fixed merely because local checks are green.
