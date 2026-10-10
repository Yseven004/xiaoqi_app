# Project agent instructions

## ARTEMIS availability

- If ARTEMIS tools are absent from the current tool list, ignore ARTEMIS-specific workflows and do not attempt to diagnose or install ARTEMIS. Continue with the tools that are available and state any device-level verification that could not be performed.

## Remote service deployment

- For backend or service changes in this project, treat local code changes and updating/restarting the matching remote service as one task. Verify the deployed service after release when possible.
- When Alibaba Cloud authorization is needed, launch `aliyun configure --mode OAuth --profile xiaoqi-remote-deploy` so the user can authorize in the browser. Never ask the user to paste access keys or passwords into chat.
- Preserve the remote service's existing environment, secrets, and persistent data. Keep a rollback path and report any deployment or verification blocker explicitly.
