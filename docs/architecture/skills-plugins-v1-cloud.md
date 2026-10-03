# Skills / Plugins V1 cloud service

## Decision

Keep skill bundles and task material in a private OSS bucket. Store mutable
ownership, version pointers, pairing state, device credentials, preferences,
deletion markers, task state, and event sequence numbers in Tablestore.

This is needed for the plan's conditional-write guarantee: Alibaba OSS rejects
`If-Match` and `If-None-Match` on `PutObject`. Tablestore supports row updates
conditioned on an attribute value, including compare-and-swap on a revision.
Upload content under an immutable OSS key first, then conditionally move the
Tablestore version pointer. A failed compare returns a conflict and leaves the
local draft intact; the unreferenced object is eligible for later cleanup.

- [OSS PutObject conditional-header limitation](https://www.alibabacloud.com/help/en/oss/user-guide/0017-00000245)
- [Tablestore conditional updates and CAS](https://www.alibabacloud.com/help/en/tablestore/developer-reference/python-conditional-updates)
- [Tablestore Python SDK](https://www.alibabacloud.com/help/en/tablestore/table-store-service/developer-reference/python-sdk/)
- [OSS prevent overwrite with Python SDK](https://www.alibabacloud.com/help/en/oss/developer-reference/prevent-objects-from-being-overwritten-by-objects-that-have-the-same-names-2)

## Data layout

All rows and object keys are scoped to a server-derived `user_id`; clients
cannot choose another user's prefix.

| Table | Primary key | Purpose |
|---|---|---|
| `xiaoqi_pairings` | `pairing_hash` | One-time code, owner ID, expiry and state |
| `xiaoqi_devices` | `user_id`, `device_id` | Revocation state and device label |
| `xiaoqi_credentials` | `token_hash` | Token lookup to owner/device; never store raw tokens |
| `xiaoqi_capabilities` | `user_id`, `capability_id` | Current immutable version pointer, content hash, revision, visibility and tombstone |
| `xiaoqi_drafts` | `user_id`, `draft_id` | Cloud draft object pointer and revision |
| `xiaoqi_tasks` | `user_id`, `task_id` | Idempotency hash, state, cancel flag, worker ID and event sequence |

Immutable package keys use `users/{user_id}/capabilities/{id}/versions/{version_id}/{sha256}.zip`.
Task attachments and output artifacts use separate per-task prefixes. All buckets
stay private; downloads pass through the authenticated service.

Provision tables and least-privilege RAM roles once per environment. Function
configuration carries table/instance names, OSS bucket/endpoint, pairing admin
secret, and Alibaba RAM credentials. No cloud credential belongs in Flutter.

## Pairing and authorization

1. An operator calls the pairing-code endpoint with the server-only admin
   secret. Codes are random, stored only as a hash, expire after five minutes,
   and belong to `XIAOQI_TEST_USER_ID`.
2. A device redeems a code once. A Tablestore conditional update changes
   `issued` to `consumed`; repeated or expired redemption fails.
3. The service returns a random device token once and stores only its SHA-256
   hash. Every request resolves the token to its owner and checks that the
   device is not revoked. Revocation invalidates that token immediately.

## Conditional skill commit

1. Validate the skill package and size limits; compute SHA-256 and immutable
   version ID.
2. Upload the package with OSS `x-oss-forbid-overwrite: true`.
3. Insert a new metadata row with `EXPECT_NOT_EXIST`, or update an existing
   row only when both `revision` and `current_version_id` match the request's
   base values.
4. On a failed condition return HTTP 409 with the current remote version
   summary; keep the local and remote versions as separate drafts.
5. Store visibility changes and deletion tombstones with the same CAS. A
   tombstone remains queryable so an older device cannot resurrect the skill.

## Agent tasks

Use a dedicated Function Compute asynchronous worker with Task Mode enabled.
The API writes a task row using `EXPECT_NOT_EXIST`, then invokes the worker
asynchronously with the caller's `task_id` as the FC async-task ID. Repeated
IDs return the existing task. A worker renews the task revision and cancellation
state before each model or tool call; cancellation prevents further calls and
kills any active E2B sandbox. Recovery reconnects to a recorded sandbox/task
state, then marks terminal results and immutable events for clients to fetch.

The task request contains the selected model, conversation branch, capability
IDs and immutable version IDs, and references to uploaded task material. Event
content contains streamed text, safe tool-call records, draft previews, test
results, status changes, and bounded errors. Do not store model API keys or raw
device credentials in task payloads.

## Locked Python dependencies

```text
aliyun-fc2==2.5.2
tablestore==6.4.8
oss2==2.19.1
e2b-code-interpreter==2.10.1
e2b==2.52.0
```

E2B internet access is disabled by default. A separately authorized domain
allow-list is passed to the sandbox egress rules; Python execution itself does
not require confirmation. The worker always closes the sandbox in `finally`.

## Delivery state

Local Flutter selection, draft/version storage, user-controlled saving,
visibility, tombstones, and message metadata are implemented. Cloud resources,
credentials, the API/worker endpoints, E2B execution, and deployment are not yet
configured or verified in this repository state.
