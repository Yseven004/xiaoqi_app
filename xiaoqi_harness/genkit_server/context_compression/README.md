# Official Genkit context compression

Direct runtime dependencies (reviewed 2026-11-05):

- `@genkit-ai/middleware` **0.12.0**, Apache-2.0. The unmodified `contextCompression` middleware owns truncation, summary boundaries, tool request/response pairing and compression metadata.
- `genkit` **1.44.0**, Apache-2.0, required peer dependency.
- Node 24, shared with the existing sandbox image's base family. npm dependencies are locked by `package-lock.json`, installed in CI, and included in the prebuilt server image. Production does not install packages or build them.

Sources: [official middleware documentation](https://genkit.dev/docs/js/middleware/), [upstream implementation](https://github.com/genkit-ai/genkit/blob/main/js/plugins/middleware/src/context-compression.ts), [release notes](https://github.com/genkit-ai/genkit/releases/tag/genkit%401.44.0).

`compress.mjs` is only a stdio adapter around the package's public `instantiate`, `generate` and `model` hooks. It returns both the original transcript with official compression metadata and the inference view. It never executes tools or opens a public endpoint. The Dart host performs summary calls through its existing model client, cancellation and budget limits; no credentials are sent to the Node process.

The configured soft budget is 80,000 estimated input tokens. Old tool results may be shortened; older context is summarized with the most recent eight messages retained. No `maxMessages` deletion policy is configured. Original messages and receipts remain in session state. If a summary call fails, the official component retains its documented fallback behavior; if the component itself fails, the host stops the call rather than restoring the removed custom cropper.

This replaces the previous 48,000-character / recent-turn cropping engine and its custom action ledger. Dart's `history_context.dart` only removes stale skill instructions from the model view; it no longer compresses history.
