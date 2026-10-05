# Xiaoqi Skills backend

Deploy two Function Compute functions from this package:

- `fc_proxy_function.py` keeps `/v1/chat/completions` and the capability APIs.
- `fc_agent_worker_function.py` exposes only the internal task run and cancel
  routes. The API function invokes the worker's run route asynchronously.

The existing `xiaoqi_harness/deploy/xiaoqi-agent-worker.zip` is the legacy archive. Build the API update package, Harness-capable worker, and the worker's dependency layer on Linux x86_64 with Python 3.10:

```sh
python3.10 xiaoqi_harness/deploy/build_worker_artifacts.py --output-dir /tmp/xiaoqi-harness-artifacts
```

On Windows x86_64, the same builder can cross-package the Linux layer when `uv` is installed:

```powershell
python xiaoqi_harness/deploy/build_worker_artifacts.py --output-dir $env:TEMP/xiaoqi-harness-artifacts
```

The output contains three archives:

- `xiaoqi-agent-api-harness.zip` updates the existing API function. It includes both API entrypoints and their Python dependencies; keep that function's current startup command and URL.
- `xiaoqi-agent-worker-harness.zip` is the new worker's code package.
- `xiaoqi-agent-runtime-layer.zip` contains Python 3.10 dependencies built for Linux x86_64. Because the worker function runtime is `custom.debian11`, publish the layer with `custom.debian11` in `compatibleRuntime` and attach it only to the worker. Set its startup command to `python3 fc_agent_worker_function.py` and listening port to `8080`.

The builder preserves the existing legacy archive. Verify the API and worker cold starts in the target region before adding any test tenant to `CAPABILITY_HARNESS_TENANTS`.

## Function configuration

Install `xiaoqi_harness/requirements.txt` for the worker and
`xiaoqi_harness/requirements-api.txt` for the API function. The Harness runtime
is worker-only, so it is not included in the API package. Configure values in
Function Compute, never in Flutter or a checked-in environment file.

Both functions need the shared storage settings:

| Variable | Purpose |
| --- | --- |
| `OTS_ENDPOINT`, `OTS_INSTANCE`, `OTS_REGION` | Tablestore endpoint, instance, region |
| `CAPABILITY_TABLE` | One String primary key column named `pk`; default `xiaoqi_capabilities_v1` |
| `OSS_ENDPOINT`, `OSS_BUCKET`, `OSS_REGION` | Private OSS bucket for skill packages and task files |
| `ALIBABA_CLOUD_ACCESS_KEY_ID`, `ALIBABA_CLOUD_ACCESS_KEY_SECRET` | Server-side RAM identity with least-privilege OTS/OSS access |
| `ALIBABA_CLOUD_SECURITY_TOKEN` | Optional STS token when short-lived credentials are used |

The API function also needs `CAPABILITY_ADMIN_TOKEN`,
`CAPABILITY_TASK_INTERNAL_TOKEN`, `CAPABILITY_TASK_FUNCTION_URL` (ending in
`/v1/internal/agent/tasks/run`), `CAPABILITY_TASK_CANCEL_FUNCTION_URL` (ending
in `/v1/internal/agent/tasks/cancel`), and `DEEPSEEK_API_KEY` for the existing
chat proxy. The model-aware chat proxy also needs `MIMO_API_KEY` so requests for
MiMo models use Xiaomi's API instead of being sent to DeepSeek.

For personal account email login, configure these additional values on the API
Function Compute function. Do not put the QQ Mail authorization code in Flutter
or in a checked-in environment file.

| Variable | Purpose |
| --- | --- |
| `CAPABILITY_OWNER_EMAIL` | The one email address allowed to sign in |
| `CAPABILITY_SMTP_USERNAME` | The QQ Mail sender address, usually the same address |
| `CAPABILITY_SMTP_PASSWORD` | QQ Mail's SMTP authorization code, not the mailbox password |
| `CAPABILITY_SMTP_HOST`, `CAPABILITY_SMTP_PORT` | Defaults to `smtp.qq.com` and SSL port `465` |
| `CAPABILITY_AUTH_CODE_PEPPER` | Random server-only secret of at least 32 characters for hashing login codes |
| `CAPABILITY_API_RELEASE_ID` | Build or commit identifier returned by `/health` for deployment checks |

The app requests a short-lived email code at `/v1/auth/email/start` and signs in
at `/v1/auth/email/verify`. A successful session uses the existing `personal`
tenant and capability storage. The new app flow does not require pairing codes.

The worker function needs the same `CAPABILITY_TASK_INTERNAL_TOKEN` and model
provider keys (`DEEPSEEK_API_KEY`, `MIMO_API_KEY`), plus the Alibaba Agent
Sandbox settings below. Configure both model keys on the API and worker
functions; keep the Sandbox API Key on the worker function only.

The Harness profiles use a 1,000,000-token context window for both
`deepseek-flash` and `mimo-v2.6-flash`. The current Agent profile limits each
model response to 8,192 tokens. Model specifications were checked against the
[DeepSeek model documentation](https://api-docs.deepseek.com/quick_start/pricing/)
and [Xiaomi MiMo-V2.6-Flash documentation](https://mimo.mi.com/models/zh-CN/mimo-v2.6-flash)
on 2026-10-05.

On the API function, Harness routing is opt-in per tenant through `CAPABILITY_HARNESS_TENANTS`, a
comma-separated list of tenant IDs. Leave it empty to keep all new tasks on the
existing worker. DeepSeek `deepseek-flash` image tasks and MiMo text tasks now
have local ACP compatibility coverage. MiMo image tasks and image tasks using
other models stay on the existing worker until the exact vision route is verified.
Enable the tenant allowlist only after the worker package, layer/runtime size,
Function Compute startup, and E2B tool path have been checked in the target region.
The current Hangzhou trial keeps the allowlist restricted to `personal`; expand it
only after the remaining migration checks in the migration plan pass.

| Variable | Purpose |
| --- | --- |
| `E2B_API_KEY` | Server-side Alibaba Agent Sandbox API Key |
| `E2B_API_URL` | Agent Sandbox API endpoint, e.g. `https://api.cn-hangzhou.sandbox.aliyuncs.com` |
| `E2B_DOMAIN` | Agent Sandbox region domain, e.g. `cn-hangzhou.sandbox.aliyuncs.com` |

Create the Tablestore table with one String primary key column `pk`, and grant
the Function Compute role access only to that table and the private OSS bucket.
Enable Function Compute asynchronous task mode on the worker's HTTP trigger;
the API supplies `X-Fc-Invocation-Type: Async` and a stable per-attempt
`X-Fc-Async-Task-Id`. The worker also exposes a synchronous, authenticated
cancel route so the API function never needs the Sandbox API Key. Configure API
Gateway rate limits for email-code requests and task creation before exposing
the API function.

The legacy pairing-code endpoints remain available for rollback, but new app
installs sign in with the personal email account and do not need pairing codes.

Mutable documents use Tablestore conditional writes on the `revision` column.
Skill versions are ZIP objects whose keys include the immutable version ID and
SHA-256 digest; OSS rejects a same-key overwrite. Task checkpoints use a
separate private, mutable prefix. A tombstone remains in Tablestore so an older
offline device cannot silently recreate a deleted skill.

## Current runtime limits

- Skill package and task input: 2 MB and 18 MB respectively.
- Up to 16 model/tool rounds per task; at most one Python execution per task.
- Python execution: 120 seconds; sandbox lifetime: five minutes. Text output is
  capped at 128 KB. The sandbox is killed in `finally`; a failed kill is marked
  for cleanup and the E2B lifetime remains the fallback.
- Python deliverables must be written under
  `/home/user/workspace/output`. Up to 10 files are returned, with a 10 MB
  per-file limit and 20 MB total. Files are stored in private OSS packages and
  downloaded through the authenticated task artifact endpoint; every download
  is checked against its saved SHA-256 digest.
- Sandbox networking is closed by default. After task-specific user approval,
  E2B receives an outbound allowlist containing only the approved exact domains
  and a deny-all rule for the rest. Python execution itself has no permission
  prompt.
- Cancel writes a server-side cancellation flag and kills a known E2B sandbox;
  the worker checks the flag before every later model or tool call.
- `POST /agent/tasks` is idempotent for a matching task ID and request body. A
  reused task ID with different input returns `409`. A worker lease prevents
  duplicate Function Compute deliveries from running concurrently; if a Python
  execution's outcome becomes unknown, the worker reports failure instead of
  silently executing the same script again.

No cloud resources are provisioned by this repository change. Set up the table,
bucket, Function Compute async task mode, role permissions, and server
environment in a separate deployment step.
