# Plugin command binding identity

Renaming an installed plugin while a command script waits for network approval
used to change its restoration fingerprint. The fingerprint included display
metadata and selection mode, so the exact original approval could no longer
restore the command. Conversely, direct invocation recognition used that mutable
display name, allowing a rename to skip original argument comparison.

Bindings now include only tenant-selected parent, immutable version/artifact,
component, component root and source path. Existing files() validation still
rejects disabled, removed or changed components and unavailable versions.
Direct invocation matches the immutable package manifest namespace, with the
same manifest precedence used by installation. A manually constructed record
without a manifest retains its existing namespace fallback. Malformed declared
namespaces fail rather than silently falling back to a mutable name.

This does not grant additional tools or networking. Exact script approval,
scope checks, cancellation and original direct-call argument equality remain.

Validation: 11 focused command tests pass, including actual Genkit approval
interrupt/resume after display-name edits (one script execution), rejection of
changed direct-call arguments despite a display rename, and actual installer
coverage for stable fingerprints across rename and discovery/selection mode.
Analyzer passes. Broader regression and deployment are recorded when terminal.
No paid image calls or real external writes are made by these fixtures.

Remaining full-plan requirements are unchanged; this closes one command
restoration/argument-binding defect, not all component protocol support.

Local release validation: broad regression passed 329 tests after combining the
dependency recovery work. The final strengthened execution/command tests pass
35 checks and analyzer reports no issues. The 12 combined dependency/actual
Genkit command scenarios also pass, including literal script argument checks
in the renamed-command worker. CI and deployment remain pending.

Rollout completed: main eefc86087f47f336e5529b1371494901a6c2cf8d,
Actions 40699178053/job 122854008882 succeeded with 329 Dart, 60 runner and
28 deployment tests, real Docker stdio/command gates and image roundtrip.
Standard non-image deployment 20261028-214438-eefc860 exited 0; current service,
data and latest-good restore point checks passed, and public HTTPS returned 200
through the same endpoint checked by Cloud Assistant. API contract remains 24.
Primary deployment log: .codex-artifacts/deploy/20261028-214438-eefc860.log.
Server deployed and verified; client/device acceptance is separate.
