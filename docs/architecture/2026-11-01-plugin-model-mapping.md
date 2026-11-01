# Plugin Agent model mapping

Product decision, 2026-11-01: the user explicitly selected **DeepSeek V4.1
Flash**, whose existing application/provider ID is `deepseek-flash`, for imported
plugin model requirements. No new provider purchase or user setup flow is added.

## Runtime behavior

Plugin Agent declarations `sonnet`, `haiku`, `opus`, or `deepseek-flash` select
the configured DeepSeek V4.1 Flash provider. `inherit` retains the actual parent
Agent model, including a nested child's mapped DeepSeek parent. Other explicit
unknown model names remain a configuration error rather than silently changing
providers. This host mapping applies to plugin Agent execution; it does not
rewrite source archives, change the user's parent chat model, or pretend that
all other unsupported command/model fields are already adapted.

When the parent uses MiMo, the same Genkit registry also registers the configured
DeepSeek provider. Both use the existing task HTTP client and cumulative request
budget. A missing DeepSeek server key returns a recoverable unavailable result
before starting the child. Keys remain host-only; no plugin script receives them.
The host-owned `DEEPSEEK_BASE_URL` setting follows the existing MiMo endpoint
configuration pattern and permits local provider fixtures; default remains the
official DeepSeek API. Provider endpoint values join the redacted values.

The child result contains compatibility notes with the original and actual model;
runtime logs record the same declared/actual model and provider without secrets.
The private delegation binding records the actual model so recovery cannot reuse
a child session under a different model. Tool narrowing, ancestor permission,
source revalidation, cancellation and budget are retained.

## Verification

The local SDK scenario `model-alias` runs a MiMo parent and a `model: sonnet`
plugin Agent against local model endpoints. Assertions verify the child HTTP
request's actual model is `deepseek-flash`, the mapping note reaches the parent
history, the child writes the expected file, and the task's provider count equals
the combined observed provider requests. Policy tests cover all three aliases
and inherited-model selection without widening the tool set;
unrecognized models are still rejected.

The targeted policy and real SDK scenario passed (2 tests). The complete policy
and Agent regression then passed 32 tests, with `dart analyze` reporting no
issues. A subsequent direct/nested model SDK run passed both scenarios, proving
that a mapped child passes its actual DeepSeek model to an inheriting grandchild.
Exact-main CI `41269309017` passed 483 Dart, 93 runner, 30 deployment, 2 bridge
and 2 sandbox image tests, real-container gates and image roundtrip. Standard
deployment `20261101-113206-281cd51` completed with exit 0, runtime probe,
health/data, traffic resumption, cleanup and independent public HTTPS/API 24
verification. The service is healthy with one restore point and data.
This change is server deployed and verified. See
`evidence/2026-11-01-deepseek-plugin-release.json`.
A local model fixture is not a live alias-specific plugin or real-device check.
No paid image service was called.
