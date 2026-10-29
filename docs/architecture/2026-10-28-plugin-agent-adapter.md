# Plugin agent adapter — runtime release verified

The importer now discovers and reindexes Agent definitions from immutable plugin
versions. The task runtime registers directory, delegation and resource tools,
instantiates actual SDK child agents, and keeps loaded versus completed source
bindings separate. The runtime integration is deployed as release
20261029-073744-a8b1c00. It does not close the whole P11 or P01–P14 plan.

Genkit 1.0.0 agents middleware cannot propagate resumable child interrupts.
The core uses the actual SDK Agent/chat/session API instead, preserving child
state and original ToolRequestParts in private server documents. Scope,
invocation, definition and task bind restoration. Client/model payloads cannot
supply child messages. Existing approval data is passed through existing cards.

The SDK requires all pending requests on resume. Only the selected request gets
the human decision; undecided requests re-enter their approval guard without a
grant. Completed pendingOutput requests are excluded, even though Genkit 1.0.0
retains their old interrupt marker. This behavior is verified against the locked
SDK without modifying the dependency. Runtime tools must approve before effects.

One durable delegation reservation survives resumes. Child HTTP requests and
tools share existing task budgets. Scope changes/cancellation block execution.
Unconfirmed active child state is preserved without restarting its task. A child
session ending normally is not proof of the parent's delivery contract: actual
parent tool/artifact evidence remains required.

The parser validates YAML/name/description, inherited versus explicit-empty
tools, allow/deny lists, model/turn count and behavioral field types. It preserves
host metadata for policy mapping, not authority. Default/custom source locations
stay inside the package; malformed files do not hide healthy siblings. Plugin
root substitution is literal. The shared immutable registry extraction preserves
existing command aliases, fingerprints and tenant/source/version validation.

References read 2026-10-28: installed Genkit/genkit_middleware 1.0.0 (Apache-2.0),
the project's developing-genkit-dart agents/HITL/multi-agent references, the
[official agent example](https://github.com/anthropics/claude-plugins-official/blob/main/plugins/plugin-dev/agents/agent-creator.md)
and [plugin-dev guide](https://github.com/anthropics/claude-code/blob/main/plugins/plugin-dev/README.md).
Upstream text/source is not copied; fixtures/prompts are original. Explicit model
names are preserved rather than silently replaced by a different provider.

Local evidence: 25 parser/command/session/budget/reconciliation tests and analyzer
pass. Session tests run the actual SDK/OpenAI adapter with a fake HTTP client
wrapped by TaskModelClient: two consecutive approvals across database/registry
rebuild, one effect each, denial, task stop, scope/version/task mismatch, unknown
state, one reservation and provider-budget exhaustion without effect replay.

Runtime integration (2026-10-29):

- `search_plugin_agents`, `run_plugin_agent`, `read_plugin_agent_resource` expose
  actual delegation, with original SDK invocation refs, bound source fingerprints
  and server-owned ancestry. Sibling discovery retains the selected version.
  A child cannot rewrite the parent's delivery plan or stream public final text.
- Source tool allow/deny lists narrow the available parent tools. Read/Write/Edit
  map to task artifact IO, never arbitrary code execution. Existing files require
  an exact latest version for writes/edits and retain earlier versions. Reads
  validate tenant/task ownership, hash, byte count and UTF-8 before returning text.
  Unicode pagination is bounded; these helpers do not expose API-host paths.
- Nested children inherit read-only and dontAsk restrictions. `bypassPermissions`
  never grants permissions: it suppresses new prompts for unauthorized actions.
  Plan mode additionally checks the authoritative MCP effect at invocation.
- Live source checks accompany native tool execution through asynchronous zones.
  Every existing ToolExecution checkpoint revalidates source authority after
  waits; nested checks compose without sharing mutable callbacks across tasks.
- Child SDK stop text alone is insufficient for success: unresolved tool errors,
  denials and unknown results prevent a completed delegation. Parent completion
  still requires the actual bound tool/file evidence and explicit Agent execution.
- Local actual-runtime fixtures cover writing a verified file, nested delegation,
  provider-invented forbidden writes, original MCP approval across runtime rebuild,
  denial/dontAsk, disabling a pending source, plan-mode non-read MCP rejection,
  and Agent-owned script network approval/resume with one runner execution and
  temporary network authority cleared afterward.
  All provider traffic and MCP effects in these tests are local fixtures.

Known remaining adapter work (not silently treated as successful): explicit model
names require the configured model rather than a silent provider substitution;
nonempty skills/mcpServers/hooks/memory/isolation and background mode report setup
issues pending their host adapters. Glob currently provides prefix-based task-file
listing, and Grep provides bounded source/material reads, without claiming CLI
pattern/search parity. Script-bearing Agent bindings use the existing isolated
runner and original pinned package. The script acceptance fixture exercises the
actual harness protocol with a local Python worker; it makes no external request.

Validation before release: the broad local run passes 367 tests. The final source
authority changes, registry checks and script fixture then pass 34 targeted tests;
full server analysis reports no issues. The exact final commit still requires full
CI (including runner/deployment and Docker gates) and standard deployment. No
device/client acceptance or full-plan completion is implied.

Release evidence (2026-10-29): main a8b1c00d8364099975e879a03cf8666df7fb7fdc;
CI 40788639436, job 123168028061, completed success. All 372 Dart, 60 runner and
28 deployment tests pass, along with real isolated stdio gates and verified image
export/import roundtrip. The non-image standard controller exited 0. Service is
healthy, public HTTPS returns 200 through the same endpoint via Cloud Assistant,
data checks pass, and the one latest-good emergency restore point/data backup is
present. Product 2026-10-27-agent-tools-2 and API contract 24 match. Local public TLS
failed on Windows, so the controller used its existing remote HTTPS verification.
Log: primary checkout `.codex-artifacts/deploy/20261029-073744-a8b1c00.log`.
Paid image checks remain explicitly deferred; no client/device acceptance is claimed.

Hooks/apps/extensions and remaining P01–P14 requirements retain their full scope.
