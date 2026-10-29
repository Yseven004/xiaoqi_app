# Mixed file and inline plugin MCP declarations

PluginDependencies.declarations previously filtered array entries to strings,
silently losing valid inline server maps. It also deferred file reads behind
inline maps, which could reverse the declared override order. Import inspection,
dependency preparation and runtime selection share this parser.

The parser now queues paths and inline maps in declaration order. A later server
definition replaces an earlier one. Repeated file maps participate at their
declared position using cached source data; cycle expansion is still prevented.
Invalid primitive entries retain the prior ignore behavior and do not become
connections or hide valid siblings. Existing reference budgets are unchanged.

Parsing never starts servers. The resolver still binds remote URLs only to
enabled connections in the current tenant, and resolves stdio commands against
the immutable installed package in isolation. No credentials, network grants,
host executable access or external-effect authorization are added.

All 16 capability-chain and isolated-spec checks pass, including mixed import
discovery, override order, repeated files, final stdio command selection and
another tenant's URL connection not being inherited. Full Dart analysis passes.
The standard Docker gate retains its original Agent/MCP/Shell/command loop and
adds a second isolated-tenant loop. Its file-based default references a missing
executable; only the later inline official filesystem declaration can produce
the three verified artifacts. Actual CI execution and deployment of this new
case remain pending; native parser checks do not prove that gate passed.

Reference checked 2026-10-29, reference only; no upstream code copied:
https://code.claude.com/docs/en/plugins-reference#mcpservers

No client contract or stored-package migration changes. Standard deployment
rollback applies. Root hooks/apps/extensions and other open plan requirements
are not closed by this parsing/runtime selection fix.
