# Hook protocol channel and literal argv fixture

P11/P12 increment. Root hooks and the complete permissions plan remain partial.

## Actual Docker failure identified

CI 40901373409/job 123544254798 on main 1ca616e passes 455 Dart, 87 runner and
30 deployment checks, then fails the real hook Agent gate. Its bounded diagnostics
show the Python pre-hook failing `assert 'agent-shell-verified' in command`.
That string is an independent argv value, not part of the Shell code. The
runtime correctly supplied separate command and arguments. This assertion was a
fixture error, not evidence of a permission rejection.

The fixture now independently checks command contents and literal argv. The
actual Shell code and arguments are shared between the Docker Agent driver and
native Python pre-hook verification. The gate still requires actual rewritten
Shell execution, its fourth file, a successful post-hook, exact file contents,
and four total code attempts. It has not been weakened to metadata-only proof.
The controller exits 1 before activation; production remains on the previously
verified 20261029-191909-6f2831d release.

## Preserve valid large verdicts

Code inspection also finds a separate transport mismatch. Command hooks accept
up to 128 KiB of combined stdout/stderr, but ordinary execution returns only the
last 40000 stdout characters. A valid large JSON deny decision could therefore
be sliced into an invalid tail and handled as an output failure.

The host-owned plugin_hook execution profile now preserves a bounded MiB of
stdout in both the immediate result and its durable checkpoint. A 128 KiB child
payload escaped into a JSON envelope fits within that existing log-decoder
bound, including control-character escaping. The launcher retains its 128 KiB
raw child output cap. Ordinary code keeps its existing 40000-character tail.
The API, Python bridge and runner recognize the same private profile together.

This profile does not change the normal 120-second deadline, CPU, memory,
process limit, filesystem isolation or network policy. It accepts the host's
JavaScript launcher, not a script/MCP entrypoint. The model tool schemas expose
no execution-profile selector. Source declarations cannot raise their budgets
or use this channel to grant an external action.

## Local evidence before the next CI

- Full Dart analysis passes; 39 execution-service/driver tests pass, including
  unchanged deadlines and pre-IO rejection of inappropriate private entrypoints.
- All 91 runner/bridge tests pass. Actual runner result/checkpoint paths preserve
  a 70000-character deny verdict; ordinary code still has the old bounded tail.
  The real bridge module forwards a heavily escaped payload without truncation,
  uses its normal deadline and rejects unknown profiles before transport.
- Four production-SDK root-hook scenarios pass with the private profile, including
  confirmation/resume and exact budget counts.
- Native launcher verification passes nine Node/Bash/Python cases. These include
  the shared real gate pre-hook sample, a 70000-character structured deny and
  120000 zero bytes escaped through JSON. The probe script remains below the
  normal 64 KiB code limit (43057 bytes on the development host).

No new real Docker acceptance or deployment success is claimed in this record.
The next exact-main pipeline must prove the corrected fixture and complete
transport through real isolated containers. No paid image-provider calls,
client rebuild or new hardware are part of this batch.

## Restart recovery and CI packaging correction

The exact-main run 40908412872 passed all 456 Dart tests but stopped while
building the runner: its new bridge test referenced `bin/docker_worker.py`,
which is deliberately outside that image's build context. The bridge test now
lives beside the bridge under `bin/tests` and runs explicitly in the host CI
validation step. No production files or image contents were added to satisfy
a misplaced test, and no acceptance assertion was removed.

Startup recovery also had a separate ordinary-output tail limit. Hook containers
now carry their private execution profile in an owned container label, and
recovery applies the same bounded protocol limit as live completion. Ordinary
code retains its 40000-character tail. A durable-journal recovery test checks a
120000-zero-byte escaped envelope and its exit-2 verdict; the creation test checks
the label that carries this profile across a runner restart.

Local verification: 90 runner tests and 2 separately executed bridge tests pass.
The actual Docker gate and deployment remain pending.
