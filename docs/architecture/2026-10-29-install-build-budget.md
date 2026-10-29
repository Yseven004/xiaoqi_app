# P10 shared installation budget — deployed and verified

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

Release evidence: main 3b0301d825545a08c5906a2d505ac18f6ab88a28, CI
40823869686/job 123282307050 completed success with all 398 Dart, 84 runner and
30 deployment checks passing. The real combined Python/npm build checkpoint ran
at 05:45:49 UTC and the stdio gate completed at 05:48:35 UTC with
combined_python_npm_build_over_script_deadline=true. Original MCP restart,
ordinary deadlines, all other stdio cases, resource cleanup and image roundtrip
also pass. Production release 20261029-134538-3b0301d completed the standard
non-image deployment with exit 0. Runtime/data/current-health and latest-good
restore checks pass; public HTTPS health is 200 through Cloud Assistant after
local Windows TLS verification failed. Product/API remain
2026-10-27-agent-tools-2/24. Log:
`C:/Users/20833/Desktop/xiaoqi_app/.codex-artifacts/deploy/20261029-134538-3b0301d.log`.

The frozen-source release APK builds successfully (Gradle 533.6 seconds), with
the same signing certificate as the previous client. Its three ABI binaries carry
the expected product and public endpoint markers. Current delivery:
`C:/Users/20833/Desktop/xiaoqi_app/.codex-artifacts/client-current/app-release.apk`,
369817076 bytes, SHA256
1cfb9c52cbd1fc2bc5e509e178e8cb7a45be775a0d803d9426f7c7dff522ab01.
Manifest and artifact hashes were checked after copying. Client/device visual and
on-device behavior verification were not performed; those remain user-owned.

A read-only post-release inventory examined all 14 stored package versions:
three contain shebang scripts without recorded source execute modes, including
one GitHub source with a recoverable revision and two with unknown origins. None
is currently enabled. No package data was changed by the inventory. Historical
task-copy compatibility remains outstanding rather than inventing lost metadata.
See docs/architecture/evidence/2026-10-29-source-executable-inventory.json.
