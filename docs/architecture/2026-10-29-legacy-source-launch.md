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
