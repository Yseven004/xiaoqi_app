# P11 Markdown command adapter (in progress)

Previously importing a plugin marked all `commands` unsupported. Runtime selected
skills ignored command components, so enabling such a plugin could never invoke
its commands. This batch implements the prompt-command path through existing
installation, discovery, task execution and public process rows.

Import recognizes `commands/*.md` and contained custom relative file/directory
declarations from Claude-style manifests. Each component preserves its source path
and plugin root; invalid siblings remain separately unsupported. Descriptions,
user-only flags and script availability are indexed. Actual import/install tests
exercise command-only plugins without manufacturing a skill component.

Existing installations are included: old versions whose importer discarded
command metadata are lazily reindexed from their already stored immutable
package. A version-local profile marker prevents repeated work. Current records
whose previous importer already established there were no commands can advance
the marker without decompressing the package. Reindex uses CAS, preserves other
component metadata, the pinned source version, artifact key/bytes, user metadata,
enablement and credentials; it never runs code or installs dependencies. A bad
package does not hide healthy plugins. Import/install tests simulate the old
discarded-command record and verify automatic recovery with unchanged version
and artifact, so reinstallation or a repository update is not required.

The tenant-bound runtime directory includes selected pinned versions and other
enabled plugins, respecting exclusions and never substituting an unavailable
explicit version. Search returns 50 metadata records per page; the full directory
is independent of the classifier's bounded metadata sample. `run_plugin_command`
loads the immutable source, expands `$ARGUMENTS`, `$0` and indexed arguments with
quoted/empty-argument handling, and maps plugin-root references to a scoped
resource URI. Replacement occurs once; inserted values cannot become new
templates or shell expansion. A literal `/plugin:command` invocation must retain
the original user's arguments. User-only commands require that invocation or an
explicit component selection, even if the model attempts a call.

Command loading is task-local work and not completion of its instructions. The
model then invokes real tools; a task plan checks their actual success. Explicit
command selection requires a successful load, with active component/version
provenance. Text references use a separate path-validated read tool. No arbitrary
host path or another tenant/version/alias can be resolved. Script files are
passed to the existing isolated `execute_skill_script` path, with the command ID
as the verified capability reference. Generic code/search can use that reference
too. Commands do not grant themselves network or external-action permission.
Existing exact action approval, budgets, material fingerprints, cancellation,
revocation and before-submit rechecks remain in the execution path.

A private scope-bound command-load fingerprint survives approval resume. Resume
revalidates current plugin/immutable version before restoring loading evidence;
new user scopes clear it. This avoids asking the model to reload or losing
permission in the middle of an already approved script call. Public process rows
use existing UI with command/search/reference labels; no new client flow or API
contract is introduced. Client models already preserve arbitrary component maps.

References inspected 2026-10-28: official
[Claude plugin manifest reference](https://code.claude.com/docs/en/plugins-reference)
and [skills argument conventions](https://code.claude.com/docs/en/skills).
The official [plugin-dev command example](https://github.com/anthropics/claude-code/blob/main/plugins/plugin-dev/commands/create-plugin.md)
illustrates Markdown frontmatter and arguments; that repository's
[license](https://github.com/anthropics/claude-code/blob/main/LICENSE.md)
is Anthropic commercial terms, so no example source is copied or bundled.
Tests use original synthetic fixtures. Agent Plugins
[1.0.0 schema](https://agent-plugins.org/schemas/1.0.0/plugin.schema.json)
assigns no semantics to client-specific extension bodies; this adapter does not
treat arbitrary extensions as Claude commands. Dependencies remain unchanged.

Local validation: 315 complete Dart tests pass. A later five-case actual Genkit
loop matrix passes: command resource/quoted arguments, direct user invocation,
changed direct arguments rejected, automatic invocation of a user-only command
rejected without false completion, and exact network script approval/resume with
one execution. Provider-request counts still equal actual fixture POSTs. Import
and registry tests cover command-only install, mixed invalid siblings, 160
commands, custom paths, tenant isolation, disabled plugins and missing pinned
versions. Static analysis is clean. No paid image or real external send occurs.

After adding the metadata upgrade, 32 focused import/command/public-process
checks pass, including unchanged-version old-install recovery. An initial check
command referenced a nonexistent intent test filename; it was corrected and the
actual selected test files completed with exit 0. Final static analysis passes.

The real Docker stdio gate now also loads a plugin command and invokes its Python
script with literal argv, checks the resulting file's bytes and verifies no
shell-substitution file was created. MCP and Shell checks remain in that same
task. CI executed this gate successfully; local Docker is unavailable.
Client/device verification and real-service effectiveness remain separate.

Released as main `4e682a08da3648632160ada7ba9c732980db68df`, CI `40674011008`,
job `122767667897`: 318 Dart, 60 runner and 28 deployment checks pass. The real
Docker JSON records `plugin_command_script_loop=true`, existing MCP/Shell and
network boundaries pass, and `IMAGE_ROUNDTRIP_VERIFIED` succeeds. Deployment
`20261028-184101-4e682a0` completed with controller exit 0: healthy service,
public HTTPS 200 via Cloud Assistant, verified data/cleanup and one latest-good
restore point with data. This is deployment evidence for this command profile,
not completion of all P11 protocols or real-client acceptance.

Remaining P11 scope is explicit: dynamic shell substitutions, forked/context or
model-specific commands, command-level host hooks, other host directories,
agents/hooks/apps and client-specific extension protocols still need adapters;
these are not silently executed as ordinary prompt commands. Existing plugin
dependency preparation and representative dependency-heavy command packages
still need their own end-to-end acceptance. Current partial-install client copy
in `lib/pages/extension_market_forms.dart` still says skills and needs to be
updated with the later client verification batch. This does not close P11/P14.

Production server behavior changes, so the standard clean-main CI-artifact
deployment is required. Public API remains 24; no new server/device/account is
needed. Rollback restores the previous image; extra installed command metadata
and task-load records can remain, and unsupported components are not reported as
verified execution. Existing skill/MCP paths remain separate and tested.
