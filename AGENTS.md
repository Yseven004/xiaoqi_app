# Project agent instructions

## ARTEMIS availability

- If ARTEMIS tools are absent from the current tool list, ignore ARTEMIS-specific workflows and do not attempt to diagnose or install ARTEMIS. Continue with the tools that are available and state any device-level verification that could not be performed.

## Remote service deployment

- For backend or service changes in this project, treat local code changes and updating/restarting the matching remote service as one task. Verify the deployed service after release when possible.
- When Alibaba Cloud authorization is needed, launch `aliyun configure --mode OAuth --profile xiaoqi-remote-deploy` so the user can authorize in the browser. Never ask the user to paste access keys or passwords into chat.
- Preserve the remote service's existing environment, secrets, and persistent data. Keep a rollback path and report any deployment or verification blocker explicitly.
- Preferred deployment workflow: if authorization is needed, start the OAuth flow above and let the user complete login in the browser; never request credentials in chat. Then identify and confirm the target ECS and its running service with read-only Cloud Assistant commands, and deploy through Cloud Assistant (`SendFile`/`RunCommand`) rather than relying on direct SSH. Before replacing files or restarting services, back up the current release and persistent data as appropriate, record the running image/revision as a rollback point, and leave environment files, secrets, and persistent data intact. Build/restart the matching service through Cloud Assistant, then check service health and data integrity; restore the recorded release if deployment fails. Report which deployment and verification steps actually succeeded.
