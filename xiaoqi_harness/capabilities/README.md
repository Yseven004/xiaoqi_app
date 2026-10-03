# Xiaoqi Skills backend

The Flask blueprint is registered in `fc_proxy_function.py`; the existing
`/v1/chat/completions` proxy remains available. Capability APIs are rooted at
`/v1`, and `POST /v1/internal/agent/tasks/run` is invoked asynchronously by
Function Compute with task mode enabled.

## Function configuration

Install `requirements.txt` for the existing proxy function. Configure these
values in Function Compute, never in Flutter or a checked-in environment file:

| Variable | Purpose |
| --- | --- |
| `OTS_ENDPOINT`, `OTS_INSTANCE`, `OTS_REGION` | Tablestore endpoint, instance, region |
| `CAPABILITY_TABLE` | One String primary key column named `pk`; default `xiaoqi_capabilities_v1` |
| `OSS_ENDPOINT`, `OSS_BUCKET`, `OSS_REGION` | Private OSS bucket for skill packages and task files |
| `ALIBABA_CLOUD_ACCESS_KEY_ID`, `ALIBABA_CLOUD_ACCESS_KEY_SECRET` | Server-side RAM identity with least-privilege OTS/OSS access |
| `ALIBABA_CLOUD_SECURITY_TOKEN` | Optional STS token when short-lived credentials are used |
| `CAPABILITY_ADMIN_TOKEN` | Random 32+ character secret for one-time pairing-code generation |
| `CAPABILITY_TASK_INTERNAL_TOKEN` | Independent random 32+ character secret for the worker route |
| `CAPABILITY_TASK_FUNCTION_URL` | HTTP trigger URL ending in `/v1/internal/agent/tasks/run` |
| `DEEPSEEK_API_KEY`, `MIMO_API_KEY` | Server-side provider keys |
| `E2B_API_KEY` | Server-side E2B key; read only when a Python tool is requested |

Create the Tablestore table with one String primary key column `pk`, and grant
the Function Compute role access only to that table and the private OSS bucket.
Enable Function Compute asynchronous task mode on the HTTP-triggered function;
the API supplies `X-Fc-Invocation-Type: Async` and a stable per-attempt
`X-Fc-Async-Task-Id`. Configure API Gateway rate limits for pairing-code
redemption and task creation before exposing the function.

Create one-time pairing codes by calling `POST /v1/pairing-codes` with
`X-Admin-Token` and `{"tenant_id":"personal"}`. The response contains the
code once; redeem it from **Manage my capabilities → Connect cloud sync**.
Pairing codes expire after ten minutes and are consumed with a Tablestore CAS.

Mutable documents use Tablestore conditional writes on the `revision` column.
Skill versions are ZIP objects whose keys include the immutable version ID and
SHA-256 digest; OSS rejects a same-key overwrite. Task checkpoints use a
separate private, mutable prefix. A tombstone remains in Tablestore so an older
offline device cannot silently recreate a deleted skill.

## Current runtime limits

- Skill package and task input: 2 MB and 18 MB respectively.
- Up to 16 model/tool rounds per task; at most one Python execution per task.
- Python execution: 120 seconds; sandbox lifetime: five minutes; output is
  capped at 128 KB. The sandbox is killed in `finally`, including on errors.
- E2B networking is off unless the task first receives a separate exact-domain
  authorization. Python execution itself has no permission prompt.
- Cancel writes a server-side cancellation flag and kills a known E2B sandbox;
  the worker checks the flag before every later model or tool call.

No cloud resources are provisioned by this repository change. Set up the table,
bucket, Function Compute async task mode, role permissions, and server
environment in a separate deployment step.
