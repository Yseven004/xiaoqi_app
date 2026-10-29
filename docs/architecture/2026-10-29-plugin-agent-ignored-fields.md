# Plugin Agent fields that the source host ignores

Official subagent documentation checked 2026-10-29 distinguishes standalone
project/user agents from plugin agents. Plugin-agent mcpServers and hooks fields
are ignored by the source host; plugin-level MCP and hooks belong in their root
declarations. Reference:
https://code.claude.com/docs/en/sub-agents#choose-the-subagent-scope

Xiaoqi incorrectly treated these fields as missing mandatory host configuration
and disabled the entire child. Its plugin-only Agent policy now preserves the
usable child and explicitly notes that these fields do not start connections or
execute hooks. Notes reach the child context and the parent tool result; approval
interrupts are preserved. Root plugin components remain independently handled.

This is a source-protocol mapping, not an implementation of standalone inline
MCP servers or Agent hooks. Existing Xiaoqi permissionMode narrowing, task/source
checks, inherited tools and shared budgets remain. Required memory/isolation,
unknown constraints and unavailable models still report their actual limitations.
Root hooks/apps/extensions and the remaining full plan stay open.

New real Genkit regressions cover successful task-file delivery without inline
script/connection effects, plus a parent MCP call that still requires its exact
approval and completes once after resume. Policy tests confirm identical tools,
explicit compatibility notes, and remaining meaningful configuration failures.
Full analysis passes. Exact-commit CI/deployment are pending.

The first broader native run passed 14 cases but its two Python-worker scenarios
failed without this Windows host's XIAOQI_TEST_PYTHON setting; that run is not a
passing suite. A fresh complete run uses the existing explicit Python executable.
No system permission, user account, dependency or public client API is changed.
Standard deployment rollback applies; no stored-data migration is required.

The configured complete policy/runtime suite now passes all 17 checks, including
both ignored-field cases and existing approval/denial/plan/nesting/network modes.
The ignored-field approval case completes exactly one authorized parent MCP call;
inline hook/connection declarations do not create their own execution path.
