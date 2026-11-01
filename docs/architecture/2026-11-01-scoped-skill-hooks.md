# Skill-scoped tool Hook acceptance

## Scope

Implements SKILL.md frontmatter PreToolUse, PostToolUse and PostToolUseFailure
command Hooks through the existing isolated Hook runner. Official source
references and document hashes are in `2026-11-01-plugin-protocol-sources.md`.
This is not a claim that SessionStart/Stop or asynchronous Hooks are complete.

Skill invocation registers its handlers for the task session, including later
turns. Registration and once state persist in task/tenant-owned private records.
A private child has its own registration scope; preloaded child skills do not
activate parent skill Hooks. Registration restoration only accepts the identical
currently selected/available immutable source. Removal, cancellation and current
workflow checks remain authoritative before execution and cached-result reuse.

The existing SDK skill-load middleware reports successful invocation context;
explicit skills and private preloads use the same registration path. The trusted
launcher receives a validated skill subdirectory and supports CLAUDE_SKILL_DIR.
Plugin-root scripts come from that same pinned installation, never the host.
Only unsupported declarations receive compatibility notes; healthy tool handlers
retain their own registration. Remaining required protocols stay open.

## Once and recovery

A successful once handler is removed for distinct later events. Failure, timeout
and exit-2 blocking leave it eligible. Pending execution is persisted before IO;
after restart a different event cannot blindly replay uncertain effects. Original
recovery still goes through the existing durable code-operation result path.
Concurrent matching events cannot duplicate the in-flight once effect.

The original successful event retains its complete private verdict. Approval
resume therefore preserves parameter rewrites, ask requirements and context
without executing the Hook again. Its original input digest must match. A new
event skips the handler. Root/settings once behavior is unchanged; once remains
skill-only. Existing root Hook payloads and no-Hook child contexts retain their
original durable argument binding.

## Checks and container requirements

Core parsing/output/state checks passed before integration. New actual SDK
scenarios separately passed: child once rewrite then skip, exit-2 block then
successful retry, and rewritten MCP action approval/resume. They assert that the
parent's later write is unaffected, each code attempt is charged, the approved
external effect occurs once and the Hook is not repeated on resume.

The mixed real-container gate now preloads the same skill into both private
read-only children. It requires 14 code jobs (previous 11 plus three independent
skill Hook runs), 9 Hook successes, exactly four original artifacts, two child
sessions and three distinct successful once registrations. Temporary files from
read-only skill Hooks must not be persisted. Original SKILL bytes must match.
This gate passed in exact-main CI `41284972600`, including the actual image
export/import roundtrip.

Complete targeted local regression passed 140 tests, including the old root
Hook, fork, model, import, permission and restart scenarios; final `dart analyze`
reported no issues. Exact-main CI passed 508 Dart tests (one native launcher
skip), 95 runner, 30 deployment, 2 bridge and 2 image tests. Standard deployment
`20261101-152921-4ce890b` exited 0 after runtime probe, health/data, traffic
resumption, cleanup and public HTTPS 200/API 24 verification. The service is
healthy with one latest-good restore point and its data.
This batch is server deployed and verified. See
`evidence/2026-11-01-scoped-skill-hook-release.json`.
No API or Flutter contract changed. Client 未执行验证，待用户真机验证。No paid image
service is called, and no generic computer/device control is added.
