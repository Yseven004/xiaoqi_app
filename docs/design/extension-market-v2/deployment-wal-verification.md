# SQLite WAL verification during deployment

2026-10-26: the 590b315 deployment passed both real curated-skill probes,
but failed before activation while creating the baseline store manifest.
Automatic rollback restored and verified the previous healthy service.

The stopped application's WAL database may no longer have shared-memory
sidecars. A read-only Docker volume prevents SQLite from recreating them,
even when the database connection itself uses `mode=ro`.

The manifest containers now permit transient sidecar creation. Database
connections remain `mode=ro` with `PRAGMA query_only=ON`; document contents,
revisions and object bytes are still fully checked. Immutable mode is not
used because it would omit committed WAL data during live verification.

Local deployment tests: 17 discovered, 7 passed, 10 Linux-only skipped.
The Linux CI runner must pass the remaining checks before deployment.
