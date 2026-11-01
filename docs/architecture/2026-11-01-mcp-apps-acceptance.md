# Necessary MCP Apps acceptance

User confirmed inline expansion inside chat results. This batch implements the
existing interaction review, not a general browser or computer-control service.
Product `2026-11-01-agent-tools-apps`, client/server API contract 25.

## Source and real sample

Official `modelcontextprotocol/ext-apps` protocol/reference revision
`cf599cc462406accc90ec3ca7879e3a22a9fc2a8` and the independently published
`@modelcontextprotocol/server-basic-vanillajs@2.0.4` (MIT). The npm package reports
gitHead `7af9a75da720b8a81be0f9aff47b25f75e9530ad`; it is not claimed to be a
byte-for-byte build of the reference revision. Registry integrity:
`sha512-L+IOxLjfX9oAwvnzLAMGX1pwBsIsXUsc9mB5iOTFuQ7lIaejetsrfYngPKwf9ZPHk9iCNVbHHaI7sj5dqax55Q==`.
See `2026-11-01-plugin-protocol-sources.md` for original URLs and licensing.
Local install used npm `--ignore-scripts --save-exact`, no external account/model.

Real published server advertises version 1.0.0, tool `get-time`, and resource
`ui://get-time/mcp-app.html`, MIME `text/html;profile=mcp-app`, 243831 UTF-8 bytes.
Native Node stdio initialize/list/call/resource-read succeeded. Resource bytes
exactly matched the installed published HTML. Actual HTML/SDK ran in the host's
two-frame shell in Chromium: initialize/initialized, original input/result,
Get Server Time refresh routed to a live published stdio server, and UI displayed
the returned new time. Send Log produced notifications/message. Send Message
produced ui/message and, after its own five-second deadline, notifications/cancelled
with the original request ID. No message or external link was actually sent.
Local probes are under ignored `.codex-artifacts/apps-browser-round0*.mjs`.

The synthetic shell probe verified result delivery, blocked direct fetch, and
inaccessible parent DOM. It first exposed CSP inheritance blocking proxy script;
the correction permits inline scripts across inherited policies while keeping
remote script/connect/frame/form/object restrictions and opaque source sandbox.
Source HTML is JSON escaped in trusted host code. Only trusted host knows the
native bridge nonce; neither proxy nor source is given it. Message source identity
is checked at each frame boundary. This is a self-contained, network-free App
profile; declared network destinations do not grant networking.
Screenshot capture failed because the browser window was minimized. Semantic
rendering evidence exists; no screenshot/visual comparison acceptance is claimed.

## Host boundaries

- HTML is private task-owned data; only a small descriptor enters ordinary
  authenticated artifact delivery. Source, resource URI, MIME, size and hash are
  checked. Tenant, task, original request and installed source/version are bound.
- UI actions use a typed server entry into existing SDK tools, no extra model
  request or natural-language inference of authorization from page contents.
  App-only tools stay out of model discovery; UI may call only declared app tools
  on its bound connection. Existing account/action approvals and denials apply.
- Stable call identity, persisted outcomes and unknown-outcome recovery prevent
  fresh-ID retries from replaying uncertain effects. New reads use new identities.
  Known outcomes are retained privately if revocation prevents delivery.
- Same-task concurrency is rejected. Cancellation targets only the matching
  app/call; source SDK cancellation closes its matching native confirmation and
  blocks late confirmation. Collapse invalidates bridge nonce and requests cancel.
- Original task budget, network permission, current source and scope checks apply.
  Budget exhaustion is not masked as an optional presentation failure. Resource
  reads recheck authority after await and before returning cached normalized data.
- External link opens and chat sends need native preview/confirmation. Existing
  draft and conversation identity are preserved. Navigation cannot escape into
  arbitrary remote/local documents. Static placeholders replace route spinners.

## Checks and remaining evidence

Local full server regression passed 547 tests. Final twelve resource/API/actual-SDK
tests passed after the resource authority/budget boundary changes. Final server
static analysis passed including the real-container gate implementation. New shell
and card have no static issues; the existing cloud sync file reports twelve
pre-existing style infos, no errors. Android debug APK built; 23 existing client
regressions passed. APK SHA-256
`20d8fb589fccd944569d97dc5cc652cba60fae6323928dd6bf588634a322aa0f`;
its debug kernel contains this product release identifier.

Exact runtime main `1d160891871c4aaacf9f354538aebcf84790aea1`, CI
`41310016481` / job `124858224605` succeeded: 541 Dart passed, 6 native-only
skips, 95 runner, 30 deployment, 2 bridge and 2 image checks. Official App
isolated offline stdio gate verified package integrity, declared resource,
owned surface and revocation; 243831 HTML bytes. Image export/import passed.
Standard deployment `20261101-211115-1d16089` exited 0: exact artifact/images,
runtime probes, data/health, traffic resume and cleanup passed. Final controller
verified healthy current release, one latest-good restore point with data,
product `2026-11-01-agent-tools-apps`, API 25, and public HTTPS 200 through Cloud
Assistant. Local public TLS failed; independent remote HTTPS succeeded.
See `evidence/2026-11-01-mcp-apps-release.json`.
The browser run above uses a controlled native bridge shim, so it does not prove
Flutter WebView/native approval behavior. 客户端未执行验证，待用户真机验证。
