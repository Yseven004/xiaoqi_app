# Network mode control ordering

P04: a delayed Off control request used to revoke every proxy for a task at its
arrival time. Turning networking back On before that request arrived could kill
a newly authorized execution. Serializing HTTP callers would not fix a control
request which timed out locally but remained in flight at the runner.

Each persisted mode change now increments `network_policy_revision` in the same
task CAS that records the mode. Off captures that exact revision before awaiting
the runtime. Code execution captures the current revision before requesting a
private runner token; both the control request and execution carry it. The HMAC
binds the task, revision and issue time. Existing before-submit authorization and
scope checks remain in force.

Under the runner's existing network lock, Off advances its revocation watermark
only when its revision is at least the existing watermark, and kills only owned
task proxies whose revision is no newer than that Off. Proxy creation checks the
signed token under the same lock and stores the revision as a container label.
An old Off cannot kill a newer proxy or lower a newer revocation watermark.
Token age and runner-key rotation continue to reject expired/restarted tokens.
The mode counter does not grant networking or replace exact action approval.

No public API/Flutter contract change, new UI, dependency, hardware or account is
required. Existing tasks start their counter at zero. API and runner are deployed
together; the private control endpoint requires the revision field. Rollback is
the standard previous-release image restore; task fields can remain stored.

References inspected 2026-10-28: Python's official
[lock documentation](https://docs.python.org/3/library/threading.html#lock-objects)
for mutual exclusion, and Docker's official
[object labels](https://docs.docker.com/engine/manage-resources/labels/)
for immutable per-container metadata. These are design references only; no source
is copied and dependencies/licenses are unchanged.

Validation: 60 runner tests pass, including revision/signature binding, delayed
Off preserving newer proxies/tokens, later Off revoking them, older Off unable
to lower the watermark, invalid revisions and real HTTP control requests. Dart
API tests hold Off inside the controller while On commits revision 2, verifying
Off retains revision 1. The execution bridge fixture asserts that grant and
execution use the same persisted revision. Complete Dart regression passes 302
tests and analyzer reports no issues. CI Docker/deployment results are recorded
when terminal.

The real Docker network gate now also starts a revision-2 proxy before delivering
a revision-1 Off and requires the new script's permitted public request to
succeed. Existing live revocation, immediate reauthorization, denied domains,
private addresses, ports and cleanup checks remain. Local Docker is unavailable;
the new real-container check must pass in CI before deployment.
