# Recover pure intent classification before stopping the task

The generated-content release (main 0ae182825033d11722688d182030165734673b68)
passed exact-commit CI 40792216077/job 123179938957, but its production runtime
probe failed before activation. The unrelated and ordinary-answer cases passed;
the text-only skill case returned the generic unresolved-scope fallback. The
previous code caught the underlying error without a diagnostic category, so the
retained log cannot distinguish provider failure from malformed structured output.
This is not evidence that the original user request was ambiguous.

Deployment 20261029-081011-0ae1828 stopped in RUNTIME_PROBE, before activation.
Read-only Cloud Assistant status and same-endpoint public HTTPS checks confirm
20261029-073744-a8b1c00 remains healthy, product/API 2026-10-27-agent-tools-2/24,
with latest-good restore data present. The failed gate was not skipped or weakened.

The router now makes at most two attempts at the same pure, tool-free classification.
No failed model output is inserted into the second request. Catalog validation,
actual user text, image constraints and business ambiguity checks are unchanged.
A valid clarification is returned immediately; it is never retried into permission
to execute. Cancellation and exhausted model budgets prevent a second attempt.
Both actual provider attempts use the existing durable task model counter.

Failure logs retain only attempt number and exception type, not prompts, model
output, credentials or provider error bodies. SDK failure causes remain available
for the cancellation/budget checks. If both attempts fail, the task still prevents
further tool execution and explains the identification-service failure instead of
asking the user to clarify an already clear request.

Eleven focused checks pass, including real Genkit/provider fixtures for invalid
then valid JSON and persistent invalid output, existing scope withdrawal/reprepare,
pure-router cancellation, budget exhaustion and valid business clarification.
Full server analysis passes. Exact-commit CI and the unchanged real non-image
deployment gate must pass before claiming this batch is deployed or effective.

Release evidence: main 86a038c88ce7047772f34de21de85190dfee6409, CI
40796668531/job 123194690682 completed success with all 383 Dart, 60 runner and
28 deployment checks plus real Docker stdio and image roundtrip gates. Standard
non-image deployment 20261029-085045-86a038c exited 0. The unchanged real text-only
skill gate now passes, alongside the other required non-image checks. Service,
data, same-endpoint public HTTPS 200 and latest-good restore point/data are
verified; product/API remain 2026-10-27-agent-tools-2/24. Windows public TLS failed,
so the existing Cloud Assistant HTTPS verification was used. Log is in the primary
checkout `.codex-artifacts/deploy/20261029-085045-86a038c.log`. This release also
includes the generated-content action binding from 0ae1828. No paid image or
client/device success is claimed.

The in-progress persistent MCP journal/channel changes are separate and are not
included in this release. No new frontend flow, provider, hardware or image call
is introduced.
