# Bind generated-content authorization to the original action

An original instruction such as “write a greeting and send it to Alice” authorizes
generated content for one action. Previously, independent intent extraction allowed
any generated body for the same recipient. If the first external response was lost,
a changed body acquired a fresh inferred grant and a different canonical journal
identity. The exact-arguments journal alone could not prevent a second submission.
The local regression reproduced this: the second authorization was `true` when it
should have required a new decision or refused an unresolved original effect.

The original grant now records hashes for the human action, protected target
arguments and chosen full arguments. No generated text or recipient is copied into
this provenance. A changed body cannot acquire another inferred grant for the same
action. A completed first action may be followed by a separately confirmed exact
action; the previous result is never misrepresented as a send of the changed body.

MCP external reservations link to that original action. Live checks before approval
and atomic operation reservations reject an in-flight or unknown original effect,
including different content, aliases and a separately recorded approval. Exact
completed operations still reuse their original result. Other targets, services,
safe reads and a new human-request scope retain their existing behavior.

Older journal entries have no reversible link to the inferred grant. If a reviewed
generated-content rule has an original grant and an unlinked external operation in
the same request is still running/unknown, new generated-content actions under that
rule wait for reconciliation or an updated human request. The migration does not
invent which recipient an opaque historic operation affected. This bounded ambiguity
does not block ordinary reads or unrelated reviewed rules.

Validation so far: the failing authorization regression is fixed; tests also cover
an independently recorded approval, other targets/services, exact result reuse,
explicit confirmation after a completed first send, new request scopes and legacy
unlinked unknown state. Actual Genkit/MCP fixtures verify one external call after a
lost response and no new approval loop, plus confirmation for changed content after
a successful first call. Eleven selected authorization/MCP checks, the complete
377-test local server suite and full analysis pass. Exact-commit CI and standard
deployment are still required. This is separate from the verified Agent release
20261029-073744-a8b1c00.

The implementation extends the existing private authorization provenance and task
operation journal. It adds no provider, credential, UI flow or new service. Rolling
back code retains the added metadata, but also restores the original replay gap;
keep the current healthy release until this batch passes its gates.
Deployment evidence: this change is now included in verified release
20261029-085045-86a038c, with the classification recovery fix. Exact-commit CI
40796668531 passes 383 Dart, 60 runner and 28 deployment checks plus Docker gates.
The non-image controller exited 0 after real text-skill, health/data and public
HTTPS checks; one latest-good restore point/data backup remains. See
2026-10-29-intent-classification-recovery.md for the failed prior attempt and final
release evidence. The original full plan remains unfinished.
