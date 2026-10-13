# Project agent instructions

## ARTEMIS availability

- If ARTEMIS tools are absent from the current tool list, ignore ARTEMIS-specific workflows and do not attempt to diagnose or install ARTEMIS. Continue with the tools that are available and state any device-level verification that could not be performed.

## Single-version development policy

- During the solo-development stage, maintain one current product version. Treat the Flutter client, server code, API contract, and ECS deployment as one release rather than as independently managed versions.
- Every release must carry a shared release identifier and API contract version. Before normal API use, the client and server must verify that their contract versions match; on mismatch, stop the affected flow and show both versions with a clear instruction to rebuild the client or redeploy the server.
- When a client-server contract changes, update and verify both sides in the same task. Do not add legacy-client compatibility or preserve old request formats unless the user explicitly requests it.
- Run only the current release. Keep at most one non-running emergency restore point, replace it after each successful deployment, and remove all older images, tags, backups, staging uploads, and temporary files after health and data checks pass.
- The user is responsible for product decisions and client verification. The agent is responsible for version matching, server deployment, health and data checks, automatic rollback on failure, cleanup, and a plain-language report of what actually succeeded.

## Remote service deployment

- During solo development, deployment is the agent's automatic responsibility, not a manual user step. After changing production server code under `xiaoqi_harness/genkit_server/`, runtime deployment files under `xiaoqi_harness/deploy/`, or a Flutter/server API contract, the agent must run the relevant checks and then run `xiaoqi_harness/deploy/deploy_current.ps1` before claiming the task is complete. Do not ask the user to run the deployment command.
- Do not deploy for Flutter-only UI changes, documentation-only changes, test-only changes, or comments/formatting that cannot affect the running service. When uncertain, inspect the actual diff and deploy only if the ECS runtime or its API behavior can change.
- If required checks fail, do not deploy broken code. Fix the failure first; if it cannot be fixed within the task, leave the current healthy server untouched and report the blocker. If deployment starts and fails, rely on the scripted automatic rollback and verify that the restored service is healthy.
- Every final report for a development task must say either “server deployed and verified” or “server deployment not needed”, with one plain-language reason. Local implementation, server deployment, and verified effectiveness must not be presented as the same milestone.
- When Alibaba Cloud authorization is needed, launch `aliyun configure --mode OAuth --profile xiaoqi-remote-deploy` so the user can authorize in the browser. Never ask the user to paste access keys or passwords into chat.
- Preserve the remote service's existing environment, secrets, and persistent data. Keep exactly one emergency restore point and report any deployment or verification blocker explicitly.
- Preferred deployment workflow: if authorization is needed, start the OAuth flow above and let the user complete login in the browser; never request credentials in chat. Then identify and confirm the target ECS and its running service with read-only Cloud Assistant commands, and deploy through Cloud Assistant (`SendFile`/`RunCommand`) rather than relying on direct SSH. Before replacing files or restarting services, create or refresh the single emergency restore point for the current healthy release and persistent data as appropriate, record the running image/revision, and leave environment files, secrets, and persistent data intact. Build/restart the matching service through Cloud Assistant, then check service health and data integrity; restore the recorded release automatically if deployment fails. After a successful verification, keep only the new current release and one non-running emergency restore point, and delete all older rollback images, backup directories, staging uploads, and temporary files. Report which deployment and verification steps actually succeeded in plain language.
