# Dependency build result recovery

Dependency preparation previously created a new random task on every install
attempt and unconditionally deleted its journal and artifacts in finally. A
lost worker stream could therefore discard the original execution identity and
make the next install run package lifecycle/build scripts again.

Preparation now snapshots the source bytes and derives a tenant-scoped task ID
from sorted paths and byte digests. The source identity remains stable across
map order, HTTP retries and API restarts. Existing preparation records query
and acknowledge the original execution through the existing runner protocol.
An unknown result blocks resubmission; a persisted successful result is decoded
through the existing path/size/lock checks. A persisted failed result is surfaced
with bounded original diagnostics, even if it contains an apparent ZIP artifact.

Records and task objects are deleted only after all submitted operations have
persisted results and neither acknowledgement nor sandbox cleanup is pending.
An attempt that failed before any execution was journaled can be retried, since
execute journals the submitted identity before writing to the worker pipe.
Preparation calls sharing a store root, tenant and source are excluded across
service instances in the running API process. The supported single-running-API
deployment policy remains in force; this does not add a multi-writer deployment.
Store creation uses revision checking and a failed claimant cannot delete the
winner's preparation record. The local exclusion is released even if cleanup
throws.

The installer still runs only in the existing isolated runner with the existing
registry domains and script/resource limits. No new API fields, client flow,
host packages or hardware are required. Existing package bytes and installed
versions are untouched. A user retries installation through the existing entry
to query pending results. Old records already deleted by the previous code
cannot be reconstructed; this change prevents new losses.

Validation includes a native worker disconnect, database reopen, concurrent
retry refusal, unknown-result retention, successful original artifact recovery,
stable map-order identity, delayed acknowledgement, failure diagnostics and
no replay of the original execution. The initial 31-test execution-service suite
and 12 combined dependency/command checks pass; final broader regression and
rollout are recorded when terminal. Real Docker/packaging gates remain required
in CI. This addresses the P10/P13 install-recovery defect; longer build budgets,
other component protocols and overall plan acceptance remain open.

Final local evidence: broad regression passes 329 tests; the final 35 execution
and command checks pass after strengthening the recovered-failure and source
binding cases, and analyzer is clean. Recovered failures that include a ZIP are
rejected with their original diagnostic; the journal is retained while the
first acknowledgement fails, then removed after acknowledgement succeeds.
A mismatched stored source marker is rejected without deleting the record.
CI and server deployment are pending; local tests do not prove rollout.
