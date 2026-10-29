# Python registry MCP launch mapping

## Problem and behavior

The installed sandbox supplies Python but no `uvx`. The importer previously
recognized only npx's implicit registry dependency; a valid uvx declaration
could therefore appear supported without installing its package, then fail at
startup. Common `uvx` and `uv tool run` declarations now use the existing PyPI
dependency preparation and immutable installed package instead of a runtime
download or an API-host executable/cache.

Supported registry forms include the bare tool, `tool@version`, `tool@latest`,
`--from package[extras]` with version constraints and a distinct executable name,
and repeated `--with` dependencies. Remaining tool arguments stay separate argv
values, including shell syntax and Unicode. Unmapped launcher options fail
explicitly during inspection rather than being silently ignored. URL/local
sources continue to require a separate source-installation mapping.

Preparation appends requirements without discarding an existing manifest and
uses the existing isolated installer, origin/hash lock and dependency budget.
Resolution requires matching installed distribution metadata. The isolated
Python process selects the requested package's unique console entry point;
missing/ambiguous entries fail without trying an arbitrary global executable.
Existing missing-dependency packages report that reinstallation is required.
No model-visible permission, outbound network grant, host environment, API
contract or client UI changes are introduced.

## References and acceptance

- [uv tool guide](https://docs.astral.sh/uv/guides/tools/) documents `uvx`,
  `uv tool run`, `--from`, version syntax, extras and `--with` (checked
  2026-10-30). This is a host mapping of the registry subset, not full uv CLI
  compatibility; no uv code or binary is copied.
- [Official time MCP documentation](https://github.com/modelcontextprotocol/servers/tree/main/src/time)
  supplies a representative uvx declaration and deterministic time conversion.
- [mcp-server-time 2025.8.4](https://pypi.org/project/mcp-server-time/2025.8.4/)
  is an MIT-licensed Python >=3.10 wheel released 2025-08-04. The fixture pins
  this version and constrains its MCP SDK to the documented 1.x API family.

Local evidence: 26 importer/spec tests pass, including real Python execution of
a trusted fixture distribution, exact argv preservation and missing entry
failure; complete Dart static analysis passes. The new Docker gate prepares the
real PyPI package, connects through the production stdio transport, discovers
`convert_time`, verifies UTC 12:00 -> Shanghai 20:00 and confirms cleanup. This
gate is added but has not yet run; no deployment/effectiveness claim is made.

## Related Hook gate correction

Exact-main CI 40912164080 passed 456 Dart tests, 90 runner tests and the separate
bridge tests, then failed the real Agent aggregate Hook assertion after all four
expected files had passed exact-content checks. Inspection found that the gate
omitted the existing MCP-start charge from its expected task budget: the mixed
case has five executions, not four. The assertion now counts one MCP startup,
Shell, installed script, PreToolUse and PostToolUse explicitly. The base case
also asserts its three executions. Hook-success and artifact-boundary checks
remain, with bounded actual counts/events added to failure diagnostics.

This is a fixture correction, not a change to budget limits. The deployment
controller terminated without activation; the prior production release remains
in place. A new exact-main Docker run must prove these assertions and the new
Python MCP roundtrip before activation. No paid image service is called.
