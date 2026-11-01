# Representative protocol sources

## Lifecycle reference checked during implementation

Official mutable references fetched on 2026-11-01, used as reference only (no
documentation text or upstream implementation copied into runtime):

- [Hooks reference](https://code.claude.com/docs/en/hooks.md), 284268 bytes,
  SHA-256 `8e4d5d8c03b5a4cd0e6fe15cc8d71d782a5acc29cf738c584337d024ff1e4ca1`.
- [Skills reference](https://code.claude.com/docs/en/skills.md), 118879 bytes,
  SHA-256 `d2a5d07c0d1cef1d1edcf30f38f6b2712ff70ac050e3d50601cd3dadb42f9097`.

Skill frontmatter Hooks activate on invocation and remain for the session,
including following turns. Skill-only `once` removes a handler after a successful
run; failure, exit-2 blocking and timeout leave it active. Agent frontmatter
Hooks instead end with that Agent; its Stop is mapped to SubagentStop. Root and
Agent declarations ignore `once`. Parent and private child session activation
must therefore be tracked independently, with current source authorization
rechecked even for persisted activation or cached output.

`asyncRewake` is a background command mode whose exit-2 result wakes the Agent
with source output as a reminder. It is not equivalent to synchronously waiting
for the command. Required adaptation must preserve task-owned cancellation,
secret isolation, bounded resources and original operation recovery. The source
host's unbounded post-background timeout behavior is not permission to remove
Xiaoqi task budgets; a bounded host difference must be explicit and tested.

These rules describe the next adapter requirements, not completed support.

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

Before the model mapping change, a Dart parser/policy probe ran against those exact downloaded
source bytes (no plugin script or external model execution): commit parsing
rejects dynamic Shell interpolation; code-explorer parses but policy reports
missing `sonnet`, `LS`, `NotebookRead`, `TodoWrite`, `KillShell`, `BashOutput`
for the available read/search host tools; security-guidance produces seven Hook
components, only its synchronous PostToolUse handler currently usable/partial.
SessionStart, UserPromptSubmit, three asyncRewake PostToolUse handlers and the
asynchronous Stop handler remain unavailable. Probe source is local diagnostics
at `.codex-artifacts/inspect_pinned_protocols.dart`, not production code or a
successful install/execute acceptance fixture.

The user asked why a model-selection decision was being introduced. No model
substitution was authorized by that discussion. The existing strict policy stays
unchanged; this sample-specific requirement must not block fork acceptance or
require the user to purchase/configure a new provider.

Subsequent explicit decision supersedes that interim state: use DeepSeek V4.1
Flash (`deepseek-flash`). See `2026-11-01-plugin-model-mapping.md` for the bounded
host mapping, actual-provider request test and release status. This does not
resolve the sample's separate legacy tool or lifecycle requirements.

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
