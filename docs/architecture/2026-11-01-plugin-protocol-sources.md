# Representative protocol sources

Read-only research on 2026-11-01. These are reference targets, not installation
or runtime acceptance claims. Existing filesystem MCP and Python time MCP remain
the executable baseline; their successful gates must not be reimplemented.

## Commands, agents and Hooks

Repository: [anthropics/claude-plugins-official](https://github.com/anthropics/claude-plugins-official/tree/a7ba5b93db0c7c8d17f3f1d25853adca79598a1a),
fixed commit `a7ba5b93db0c7c8d17f3f1d25853adca79598a1a`.
Root LICENSE at that commit is Apache-2.0. No upstream executable code was copied
or run during this inspection.

| Sample | Observed version | Necessary protocol | Current evidence / next proof |
| --- | --- | --- | --- |
| `plugins/commit-commands/commands/commit.md` | 1.0.1 | Inline shell context and command tool constraints | Source read; dynamic shell remains unimplemented. Use isolated task files only; never run this sample against the host repository merely because it requests a commit. |
| `plugins/feature-dev/agents/code-explorer.md` | 1.0.1 | Read/search tools, named model, source-bound child | Source read; `sonnet` and legacy host tool names need explicit mapping/configuration. Do not silently substitute another model or expose host shell state. |
| `plugins/security-guidance/hooks/hooks.json` | 2.0.17 | SessionStart, UserPromptSubmit, PostToolUse, Stop, conditional Bash handlers, asynchronous review/rewake | Root tool Hooks exist; this broader lifecycle is not accepted. External model requests need explicit configured credentials and authorization, not plugin import authority. |

The security-guidance sample has a real lifecycle and asynchronous requirement;
it cannot be replaced with a basic synthetic PreToolUse Hook and called complete.
Its model-based branches have not been executed. No paid image service is involved.

## Apps and client extension protocol

Repository: [modelcontextprotocol/ext-apps](https://github.com/modelcontextprotocol/ext-apps/tree/cf599cc462406accc90ec3ca7879e3a22a9fc2a8),
fixed commit `cf599cc462406accc90ec3ca7879e3a22a9fc2a8`, SDK version 2.0.4.
The root package declares MIT, but the root LICENSE records an MIT/Apache-2.0
transition and CC-BY-4.0 documentation. Resolve the particular copied files'
license before any direct reuse; no SDK code was copied or dependency added here.

The pinned README and `examples/basic-host/package.json` were inspected.
The specification route is `specification/2026-01-26/apps.mdx`.
`examples/basic-server/package.json` does not exist at this revision; the 404 is
not a successful sample inspection.

The protocol requires tool-linked UI resources, sandboxed rendering and a host
bridge for tool input/results and UI-originated tool calls. A directory named
`apps/`, a `.app.json` file, or a proprietary `extensions` manifest entry is not
by itself proof of conformance to MCP Apps. Each actual imported declaration
must be identified before selecting its adapter. Existing static unsupported
diagnostics cannot simply be removed to claim execution.

Implementation must first reuse the existing chat/file/authorization surfaces.
Any new client renderer or interaction requires the project's Product Design
confirmation before formal UI or data/API implementation. Server authorization,
revocation, cancellation, source binding and budget must remain authoritative
for every UI-originated action. Client/device validation remains user-owned.
