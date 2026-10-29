# Legacy source script launch compatibility

Historical packages can lack source executable metadata. A read-only inventory
of 14 production package versions found three with potential shebang scripts;
none is currently enabled. The inventory does not prove historical mode bits.

In the absence of a source mode manifest, the runner marks shebang scripts in
scripts/bin/libexec/hooks, and recognized root script files, executable in the
authorized task copy. Hidden paths, dependency trees, materials and arbitrary
documentation examples remain unchanged. Explicit source mode records always
take precedence, including an empty list; malformed records still reject staging.
The immutable source archive, script bytes, execution authorization, isolation,
network controls and deadlines are unchanged. No source migration or automatic
script execution occurs. Lost binary mode bits are not guessed.

Local runner verification passes all 86 cases, covering unchanged bytes and
ownership, excluded paths and authoritative recorded modes. Dart analysis of
the gate succeeds. The standard real-container gate now stages a legacy package,
directly launches its extensionless shell script with literal arguments, checks
one execution and the exact output, and compares the immutable archive hash.
Exact-commit CI and standard non-image deployment are required before this batch
can be considered released. Existing source-mode and long-build gates remain.

Rollback uses the standard deployment restore point. There is no stored-data or
client API change. Remaining P01–P14 work is not closed by this batch.

Released: main 3c9ead85aef8b60269395be60490a343b415205a, exact-commit CI
40831672535/job 123307075362 succeeds. All 398 Dart, 86 runner and 30
deployment tests pass. The real container gate reports both
legacy_source_script_direct_execution and legacy_source_archive_unchanged true;
previous source-mode, long-build, MCP restart and stdio gates remain green.
SANDBOX_RESOURCES_CLEAN and IMAGE_ROUNDTRIP_VERIFIED are present.

Standard non-image deployment exits 0 for release
20261029-145118-3c9ead8. Runtime/data checks, healthy current service, one
latest-good restore point with data and public HTTPS 200 through Cloud Assistant
pass. Local Windows public TLS checking failed, so that public check used the
same endpoint from Cloud Assistant. Product/API stay 2026-10-27-agent-tools-2/24.
Log: C:/Users/20833/Desktop/xiaoqi_app/.codex-artifacts/deploy/20261029-145118-3c9ead8.log.
This server-only fix does not require another client build; device verification
is not claimed. No image provider was called.
