# Original user request authorization (P01, in progress)

The old external-action path recognized an exact human resume approval but not
the original user's explicit execution instruction. It could therefore ask the
user to confirm an action they had just specifically requested.

The new path is limited to deployment-reviewed external actions. A verified MCP
catalog entry can declare `user_actions` keyed by tool name, each with a trusted
`description`, exact `input_schema`, and optional `generated_fields` for string
content. The tool must also have a trusted write/send/delete/payment effect.
Remote annotations, names/descriptions, imported skill/plugin text and proposed
arguments cannot install these rules. Unknown effects retain existing approval.

Before examining a proposed call for matching, a separate no-tool Genkit request
extracts intent using ONLY the captured current user instruction and the reviewed
rule. It receives no conversation, tool result, remote description, proposed
arguments, skill or planner output. It must distinguish execution from drafting,
discussion, quoted instructions, hypotheticals and negation, and quote execution
and any generation instruction literally. Parser failures fall back to the
existing confirmation card. This remains model interpretation of language;
literal quotation is supporting evidence, not proof of semantic understanding.

Non-generated arguments must be grounded in the user's literal text and match
the actual call canonically. Identifier/number boundaries reject substring
matches. Every property must be declared by the reviewed schema. Generated
content is allowed only in reviewed content fields, for write/send, and only on
an explicit generation-plus-execution instruction. Delete/payment cannot borrow
this exception. Targets, accounts, options, amounts and currency never inherit
permission from the proposed call. Missing/converted/ambiguous values confirm.

The independent interpretation is cached by scope/request, reviewed rule, tool
and full connection authority. A connection-registration watermark prevents changing
credentials/rules within an already registered connection from silently reusing the
original request. The cache uses at most two records per task operation budget
(intent and authority), survives resume, and resets on a new user scope. The
extra inference is counted by the existing task-wide provider-request budget.

Before granting/executing, cancellation, current scope, connection and authority
are checked again. An exact approval hash binds the actual arguments, schema,
credentials and rule fingerprints; provenance records the original request's
digest and rule. A denial prevents inferred new grants. Existing exact human
approval for another previously approved action retains the established policy;
denial of one action is not blanket revocation of unrelated prior approval.

No public contract/UI change or dependency is introduced. Existing confirmation
and failure flows remain. Rollback is standard image restore; additional task
fields can remain. No deployment-owned production action rules are invented for
unknown third-party services. Configuring and validating real reviewed actions,
legacy polling approvals, other tool paths and the full P01 acceptance remain
open; local mock success does not prove all skills/plugins work.

References reviewed 2026-10-28: official
[MCP tools specification (2025-11-25)](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)
for tools, schema and user control, and official
[Genkit Dart tool calling](https://genkit.dev/docs/dart/tool-calling/).
These are design references, no code is copied; the project stays on Genkit 1.0.0
and existing licenses/dependencies. We implement the product's accepted
task-scoped explicit authorization policy, not a protocol-mandated blanket allow.

Local Genkit/mock-provider/mock-MCP loop verifies a
specific send to A executes once without a redundant card, and a later proposed
B interrupts before RPC. Provider-count assertions include the separate intent
request. Parser/scope tests cover generated content, changed recipients/options,
schema changes, ungrounded evidence, unknown effects, payment amounts/currency,
denial, persistent first intent and scope reset. No real external sends or paid
image calls are made. A complete 308-test regression and a later 20-test focused
authorization/scope run pass. Final connection-authority checks, CI, rollout and
real-service effectiveness remain separate evidence, recorded when terminal.

Release evidence: main `d5d48b553c6b6d2aa44d8514710f5f01d32c5494`, CI
`40664994173`, job `122737129620` completed successfully: 309 Dart, 60 runner,
28 deployment checks and image roundtrip. CI executes both original-user send
and changed-destination mock-MCP cases. Standard non-image deployment completed
`20261028-173225-d5d48b5`, controller exit 0, healthy current server, public HTTPS
200 through Cloud Assistant, data/health verification and cleanup, one latest-good
restore point with data. This proves deployment of the reviewed-rule mechanism,
not real third-party send/payment effectiveness or all of P01. Production rules
for unknown services are not fabricated. No device verification was performed.
