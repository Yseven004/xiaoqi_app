# Bounded deployment status reads

`Invoke-GitHubBuildApi` previously aborted the deployment controller on any transient TLS/socket/read failure, including harmless polling of the current build. A failed observation is not proof that a build or remote deployment failed.

GET API requests now make at most three attempts for connection/HTTP transport errors, timeouts, HTTP 408 and selected temporary server errors (500/502/503/504), with 200 ms then 400 ms backoff and the existing per-request timeout. Credentials are resolved once, never printed, and the existing exact repository path guard remains. Unauthorized responses, other permanent errors, and rate limits are not immediately retried. POST/DELETE requests still make exactly one attempt, so an ambiguous workflow dispatch or artifact deletion cannot be duplicated.

This is limited to the GitHub API helper. Artifact redirect acquisition, Cloud Assistant job observation and model/tool calls have their own paths; this change does not claim to fix all transport recovery. It creates no new build, changes no authorization policy and never treats a read error as permission to deploy a different commit.

Reference: [GitHub REST API best practices](https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api), checked 2026-10-28. In particular, rate-limit cooldown must be honored and repeated errors must remain visible. This patch stops on rate-limit errors rather than bypassing the server cooldown with fast retries. Documentation is a mechanism reference; no third-party implementation is copied.

Local checks: the real helper with an isolated fake HTTP command recovers a GET after two connection errors and after two service errors, stops after three failed attempts, never replays POST/DELETE, and does not retry authorization or rate-limit errors. Existing exact-main/commit/run and expired-artifact rebuild tests pass. Deployment controller and public health PowerShell checks pass. Python deployment discovery reports 28 tests, with 12 executed and 16 platform-dependent skips on Windows; Linux CI remains required for those checks. Production rollout is recorded separately.
