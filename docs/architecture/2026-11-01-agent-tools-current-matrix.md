# P01–P14 current acceptance matrix

As of 2026-11-01, after verifying deployment `20261101-102152-67e29ef` and
submitting fork main `00d6c0f` to CI `41265757169`. This is an interim matrix,
not the final closure report. Historical todo tables do not override newer proof.

| Item | Existing implementation/evidence | Remaining acceptance |
| --- | --- | --- |
| P01 action authorization | Bound action parameters, connection authority, pre-submit recheck, persisted approval/denial; fork approval/revocation SDK checks | Cross-entry and representative account effects; no arbitrary real service rule invented |
| P02 coexistence | Existing real filesystem MCP + Shell + skill/command/Agent/Hook composition | Fork-enhanced container composition and further selected samples |
| P03 intent/discovery | Discovery remains available outside initial recommendation; task/source withdrawal handling | Connection-health change refresh and cross-entry cancellation |
| P04 network lifecycle | Exact network action approval, original request resume, short-lived task grant, revision ordering; no per-call task-wide disconnect in inspected production call graph | Real shared-network end-of-call versus explicit revocation, all selected entry points |
| P05 large catalogs | 121-tool SDK scenario, pagination/search/schema recheck, notification refresh and failed refresh tests | Final representative composition; do not rebuild the existing gateway |
| P06 artifacts | Real XLSX/DOCX/PDF/PNG multi-step edits, old/latest same-name versions, cross-task isolation | Resource read entry/size boundaries and final delivery flow |
| P07 stdio MCP | Original lease/process/RPC runner and API restart gates; install/start/call/end/cancel/cleanup | Verify exact coverage of remaining promises and old unbound file recovery; historical artifact-only API gap is superseded by newer response-recovery gates |
| P08 Shell | Literal argv, installed scripts, MCP file handoff, process cleanup | Selected protocol composition and client validation; ECS representative resource measurement already exists |
| P09 existing hosts | Independent component health, task/version isolation; no generic device-control scope | Actual target host declarations, dependency failure/recovery, no fabricated host execution |
| P10 installation/build | Real npm/Python/combined builds, offline reuse, execution modes, old task-copy source compatibility, original install recovery | Full chosen-sample combinations; preserve immutable archives |
| P11 plugin protocols | Basic commands, custom child Agents, preloaded skills, root tool Hooks deployed; fork has 25 import/parser + 5 ordinary command + 26 Agent local checks | Fork real-container/CI/deploy; dynamic command preprocessing, skill Hooks, necessary lifecycle/async behavior, actual Apps/client extension protocol and required design confirmation |
| P12 budgets | Shared persisted tool/code/model counters, failed/resumed work, no plan-count hard block; provider-count comparisons | Cross-entry concurrency/failure/recovery matrix. Existing ECS sample is not arbitrary concurrency/load proof |
| P13 lifecycle | Source/operation identity, unknown-effect no replay, correlated result/file preservation, real restart/cleanup gates | Cross-entry revoke/cancel/restart combinations not already proven |
| P14 release | `67e29ef` standard deployment verified health/data/API/public HTTPS/restore/cleanup; fork CI in progress | Remaining scope completion and final current-release deployment; client 未执行验证，待用户真机验证 |

## Evidence anchors

- `2026-11-01-fork-agent-acceptance.md`: exact local commands, new boundary assertions and container requirements.
- `evidence/2026-11-01-hook-exec-release.json`: current verified release and independent upload cleanup.
- `evidence/2026-10-30-hooks-python-mcp-release.json`: preceding full container/restart/image-roundtrip evidence.
- `evidence/2026-10-29-ecs-task-resources.json`: 24 overlapping MCP/code samples, about 1.01 GiB minimum host memory available; zero probe resources remaining.
- `2026-11-01-plugin-protocol-sources.md`: newly pinned reference samples and protocol/license limitations, not executable acceptance.

No paid image service is called or awaited. No new hardware, server purchase or
generic desktop/mobile control is required. No item is closed merely because
an unsupported warning disappears, an SDK test passes or a release is healthy.
