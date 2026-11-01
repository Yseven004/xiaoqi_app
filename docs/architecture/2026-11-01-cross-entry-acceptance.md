# Cross-entry permission and recovery evidence

This is a bounded acceptance record for the selected installed plugins, existing
hosts and current MCP protocols. It is not a claim about every future service,
proprietary manifest, provider or concurrency level.

## Entry matrix

| Entry | Authorization / source | Network / budget | Cancel / recovery / result |
| --- | --- | --- | --- |
| Direct MCP and catalog gateway | Actual SDK read and account-action fixtures; same action across aliases cannot replay; schema/target changes rechecked; disabled/reconfigured source refused | 121-tool SDK catalog and 240-tool directory paging/refresh; original operation and provider counters checked | `mcp_api_rpc_recovery_test.dart`, runner/API real restart gates, original lease/input/artifact evidence; cancel variants preserve one effect |
| Generic code and installed Shell/skill script | Immutable installed source, task effects and pre-submit authority check; literal argv; read-only delegate artifacts do not persist | `code_execution_service_test.dart`: withdrawal during token lookup/bridge startup, atomic code/query budget across steering/resume, failed attempts retained; actual network lifecycle gate checks revoke/regrant ordering and exact destinations | Original execution and files recovered once, acknowledgement after persistence, broken late stream cannot downgrade; cancellation retains partial results until cleanup persisted |
| Commands, Agent and context:fork | Real runtime SDK fixtures: dynamic source context, exact action approval, changed source, read-only, denied, disabled and unknown-effect cases; parent/private-child identities separated | Existing task code/model/tool budgets, explicit network approval and installed scripts; DeepSeek V4.1 Flash aliases recorded | Unknown parent operation cannot replay under a child alias; child writes/read-only isolation; exact immutable source on resume |
| Root/skill Hooks | Scoped source activation, independent parent/private child once, per-call rules and permission conditions; source checks on cached success | Hook commands use task-owned runner and budgets; async results never grant permission or rewrite/veto tools | Persisted actual background execution, startup/prompt/Stop continuation, original once serialization, cancellation and source withdrawal checks; bounded task-lifetime host profile |
| MCP resources | Same connection and previously advertised URI; task authority and current source checked before and after read, including cached return | Actual SDK resource tests: 100000-byte complete delivery and bounded model text; 33 MiB rejected by 32 MiB artifact limit | Revocation inside resources/read prevents publication; complete original bytes/ownership checked. `%TEMP%/xiaoqi-resource-sdk.log`: 3 passed |
| MCP Apps native action API | Tenant/task/source/version/HTML hash; typed bound connection; app-only tool visibility; original account grant/denial; no inferred authorization from UI text | Actual SDK App call blocked by exhausted original tool budget with no MCP invocation. Pure-tool refresh makes no provider request or model-counter increment, including when existing provider budget is exhausted | API tests cover concurrent call rejection, matching-call cancellation, unknown blocks fresh ID, original-ID recovery, known private outcome retained after withdrawal; source SDK timeout cancellation observed in browser |

The full local server run before final test additions passed 547 tests. New
targeted checks passed: official upstream reviewer SDK 1, resource SDK 3, App SDK
2 with extra shared-budget assertions. Final server static analysis passed.
These test additions change no server runtime behavior after `1d16089`.

## Representative sources and composition

- Existing real container combination: official filesystem MCP 2.0.1 + installed
  Shell/Python/npm + command/Agent/fork + root/skill Hooks, task files and binary
  artifacts. Lifecycle release `20261101-200636-f42434b`, exact CI 41304862195.
- Official Python time MCP and actual npm/Python build/reinstall/recovery gates
  remain valid; do not replace their evidence with mocks.
- Published official MCP App 2.0.4: actual stdio and browser SDK refresh, selected
  real-container gate included in Apps CI 41310016481 (pending result here).
- Official `plugin-dev@0.1.1` skill-reviewer at commit
  `a7ba5b93db0c7c8d17f3f1d25853adca79598a1a`: unchanged Apache-2.0 source in
  `test/fixtures/official-plugin-dev`, actual Agent runtime reads task data and
  completes without write/Shell tools. Controlled local provider tests dispatch,
  not semantic quality of a real-model review.

The earlier code-explorer and security-guidance sources remain stress references.
Their legacy standalone host tools and foreign model SDK/account bootstrap are
not silently renamed or given platform secrets. Necessary protocol classes are
exercised by executable selected samples above; the entire foreign host product
and every upstream plugin are not the target. An unidentified apps/extensions
directory is not treated as MCP Apps merely to remove an unsupported warning.

## Verification limits

Current ECS resource evidence is 24 overlapping MCP/code samples, about 1.01 GiB
minimum host memory available; no arbitrary-load/SLA claim. No generic desktop
or phone control, extra machine or paid image service is required or exercised.
Android debug APK built successfully. Browser semantic rendering and synthetic
isolation checks do not prove native WebView focus, approval or visual behavior.
客户端未执行验证，待用户真机验证。
