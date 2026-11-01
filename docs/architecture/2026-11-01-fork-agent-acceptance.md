# Fork Agent acceptance

Updated 2026-11-01 (Asia/Shanghai). Continues the accepted P01–P14 plan;
does not close the remaining plugin protocols or device acceptance.

## Implementation and local checks

Checkpoint `6297423` preserved the existing fork implementation. Follow-up adds
old manifest-free installation regression, preserves stable component IDs,
restores formerly unsupported fork siblings and clears only the obsolete
`commands 组件暂不支持` warning after validating all root commands.
Immutable source bytes and pinned versions remain unchanged.

Verified locally with Dart 3 SDK from Flutter 3.47.5, serial execution and
`XIAOQI_TEST_PYTHON` pointing to the installed Python 3.14 interpreter:

- `dart test test/plugin_commands_test.dart test/capability_import_test.dart --concurrency=1`: 25 passed.
- `dart test test/capability_runtime_test.dart --name text-only-plugin-command --concurrency=1`: 5 passed.
- `dart test test/plugin_agent_runtime_test.dart --concurrency=1`: 26 passed.
- `dart analyze`: no issues found.

SDK fixture assertions cover default and custom fork Agent execution, read-only
denial, exact approval resume with one external effect, rejection with zero
effects, source withdrawal and replacement during approval, unknown custom Agent
without starting a child, no parent-only history in any child provider request,
and provider request counts against shared persisted budget. Failure and rejection
never create completion evidence. These are local SDK tests, not real containers.

## Real-container gate (pending CI execution)

`bin/support/stdio_agent_gate.dart` extends the existing filesystem MCP + Shell +
installed command + root Hook composition with `commands/fork-read.md` referencing
the same read-only custom Agent. A separate direct delegation and fork must each
read the original task artifact. Search/run invocations are distinguished by
their actual arguments. Assertions require 9 charged code executions, 6 successful
Hooks, exactly 4 artifacts with original contents, one completed custom Agent,
one completed fork command, two private child sessions, unchanged SKILL bytes,
and no write/code tools exposed to the read-only children.

The host has no Docker; CI must execute this gate and the full server regression
before this batch is deployed. No local fixture is presented as container proof.

## Prior release verified

`67e29ef` was not running and no deploy job was active in read-only inspection
`t-hk071ra1rvben7k`. Standard deployment subsequently activated
`20261101-102152-67e29ef`; runtime probe, data/health, traffic resumption and cleanup
logged success. Independent status and public HTTPS verified current release,
healthy service, one restore point with data, product `2026-10-27-agent-tools-2`
and API `24`. See `evidence/2026-11-01-hook-exec-release.json`.

## Remaining scope

Fork CI/container and deployment are still required. P11 dynamic commands,
skill-scoped Hooks, necessary lifecycle/asynchronous protocols and apps/extensions
remain open and must be tied to concrete representative sources. Cross-entry
authorization/network/cancellation/recovery/budget acceptance and the final
P01–P14 matrix remain open. No paid image service was called. No API or Flutter
contract change is included. Client: 未执行验证，待用户真机验证。
