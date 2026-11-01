# Apps interaction — confirmed product scope

Scope: P11 necessary MCP Apps display and event return. This document is a
reviewable interaction specification, not an implemented or accepted client feature.

Confirmed by the user on 2026-11-01: “聊天结果内展开（推荐）”. Implement the
inline result card and the error/cancel/revoke/approval behavior described below.

## Grounding and chosen sample

- Existing target: `lib/pages/home_page.dart`, `_assistantArtifactCards` /
  `_assistantArtifactCard`: conversation result cards, 12px corner radius,
  `#FAFAFA` fill, `#E7E8EA` border, 48px minimum action targets.
- Reuse task identity, result history and current authorization UI. No global
  plugin launcher, generic computer/device control or separate account product.
- Real reference sample: ext-apps `examples/basic-server-vanillajs`, pinned
  `cf599cc462406accc90ec3ca7879e3a22a9fc2a8`; package 2.0.4, server reports 1.0.0,
  package license MIT. Read package/server/app sources on 2026-11-01. Its
  `get-time` tool links `ui://get-time/mcp-app.html`; buttons call the same
  server, send a chat message, log, and request an external link. Source inspected,
  not yet installed/executed/accepted. Root licensing must be resolved for any
  files actually reused; this proposal copies no upstream code.

## Proposed default: collapsible card in the task result

```text
Assistant response
┌──────────────────────────────────┐
│ Plugin name · Interactive result │
│ [Expand]                         │
├──────────────────────────────────┤
│ Sandboxed plugin panel           │
│ Server time: …                   │
│ [Refresh]                        │
│ Message [____________________]   │
│ [Send to this chat]              │
└──────────────────────────────────┘
Existing generated file cards
```

1. Entry: a successful tool result with negotiated MCP Apps metadata produces
   a result card. User expands it; no automatic keyboard or page transition.
2. Action: a button calls the tool on that exact connection/version/task through
   the server. Reuse existing approval when required. Plugin output creates no
   authorization; cross-server calls cannot bypass task scope.
3. Feedback: retain the previous successful result while a button says
   “Processing…”. Initial loading is a static skeleton, never a rotating page
   indicator. Errors are inline, with a user-triggered retry.
4. Exit: collapse or leave the task. Close the bridge, cancel owned pending work,
   release the renderer. Returning restores the saved last result; refresh is
   explicit and rechecks current connection authorization/version.
5. Revocation/cancellation: disable actions immediately, show the concrete reason,
   retain the already generated result. Reauthorization uses the existing flow;
   cancelled or uncertain effects are not automatically retried.

## Boundaries and other states

- No result: explain that the tool returned no interactive content; retain text
  and files. Broken HTML/handshake: show an error, not a blank success.
- External link: show destination and use existing explicit user opening. The
  sandbox must not navigate or execute arbitrary host URLs itself.
- Chat message: show the actual message before submission; send only after the
  user's explicit action. Plugin background code cannot impersonate a user.
- Secrets: no provider keys, cookies, bearer headers or account credentials in
  HTML, JavaScript bridge, task artifacts or model context.
- Budget: UI actions share persisted task budgets and audit. Request IDs are
  source-bound and idempotent; oversized inputs/resources fail with clear errors.
- Focus: dismissing keyboard with an empty input also removes focus/cursor;
  tapping a button performs it on that same tap. Preserve nonempty text.
- Accessibility: named expand/collapse controls, logical keyboard order, 48px
  controls, scalable text, readable disabled/error states.

Alternative requiring a product choice: open a dedicated full-screen panel from
the result card. This gives more room but introduces a new page and back/restore
behavior. The inline card is recommended for the first bounded release.

The user's confirmation authorizes implementation in this bounded scope. Update
client and server together if the API/data contract changes. Client:
未执行验证，待用户真机验证。
