# P10 shared installation budget — local implementation, acceptance pending

Problem: dependency preparation shared the normal 120-second code limit while
pip/npm phases had unrelated 30/40/60/85-second limits. Python followed by npm
could exceed the outer deadline even though every phase was valid. The API bridge
also stopped at four minutes and the client stopped polling after about eight.

The trusted installer now uses a dependency_build profile: 600 seconds of sandbox
execution, with one 570-second monotonic budget shared by every pip/npm phase and
30 seconds reserved for result export/cleanup. A later phase receives only the
remaining budget. Failed or uncertain operations retain their original execution
identity; no lifecycle/build command is automatically replayed.

The private runner recognizes only code and dependency_build. The latter requires
Python installer execution and cannot be used for an MCP command or installed
script entry. The Dart entry requires the original tenant-bound install task and
matching source digest in preparing_dependencies state; ordinary model tools do
not accept this profile. Normal code remains limited to 120 seconds. CPU, memory,
one code-execution slot, uid, read-only rootfs, capabilities, registries, network
revocation and cancellation controls are unchanged. A long install can occupy the
existing code slot; this batch does not add unmeasured parallel capacity.

Deadlines include the existing 180-second queue bound and 30-second export grace:
the worker uses 330/810 seconds for code/build and the API uses 350/830 seconds.
The existing asynchronous client import flow polls for at most 15 minutes using a
monotonic stopwatch. Requests/statuses/cancellation and API contract 24 are
unchanged. A rebuilt client is needed to receive the longer polling window.

Local evidence: 84 runner checks pass, using a controlled monotonic clock for
121/601-second boundaries, ordinary-code cutoff, partial-file retention and invalid-profile
rejection before resource creation. Fifty native execution/import checks pass,
including rejection of an ordinary task claiming the build budget, installer wire
profile, cancellation, old-version retention and original-result recovery. Thirty
deployment tests pass with sixteen Linux-only skips locally; seven metadata/budget
checks exercise shared remaining time and no automatic replay after timeout.
Three Flutter upload/import contract tests pass. Server analysis is clean; client
analysis reports existing informational lints, without new errors or warnings.

Real CI acceptance adds a combined Python/npm project whose Node build waits at
least 125 seconds. It must preserve the packaged Python module and generated npm
output, then execute the installed skill offline with the original isolation and
credential boundaries. Existing ordinary deadlines, cancellation, failed update,
stdio restart and resource-cleanup gates remain required. This new Docker case
has not yet run; no local Docker daemon or new machine is introduced.

Deployment uses the normal exact-main artifact workflow and non-image runtime
verification. Failed checks prevent activation; deployment retains its existing
automatic rollback and single emergency restore point. Package/file formats and
installed versions are not migrated by this batch. Historical source executable
metadata recovery and other P01–P14 work remain outstanding.

References reviewed 2026-10-29:
[Python subprocess timeouts](https://docs.python.org/3/library/subprocess.html#subprocess.run),
[npm ci lifecycle configuration](https://docs.npmjs.com/cli/v11/commands/npm-ci/).
No upstream implementation or new dependency is copied.
