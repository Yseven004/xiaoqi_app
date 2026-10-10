# Genkit Dart and server-side Docker sandbox

**Status:** Genkit server deployed to ECS; production health, authentication, persistence, and Docker sandbox checks passed. Flutter source integration is updated; rebuilding/installing the app and device-flow verification remain pending.

**Date:** 2026-10-10

## Confirmed scope

- Keep the Flutter app's existing HTTP API and user flows. Flutter does not embed the Genkit runtime and does not need a framework migration for this server change.
- Skills and drafts remain in Flutter's local storage; keep the current cloud sync and conflict APIs.
- Remove DSH-specific manager pages and ACP configuration. Do not add a replacement management UI. Model and service configuration stays in server-only environment files.
- Run the Dart Genkit API and code execution on the existing ECS. Do not run Docker builds or user code on the developer's computer.
- Use the ECS host's Docker Engine for Python, JavaScript, and TypeScript execution. Do not use Alibaba Agent Sandbox or E2B.

## Runtime and isolation

The public API remains behind Caddy for HTTPS and existing single-owner authentication. A private sandbox-runner service creates one short-lived code container per task and is the only service mounted to /var/run/docker.sock. The API reaches it over an internal Compose network with a server-only token. The task container receives no Docker socket, host directory, or privileged capabilities.

Tasks run without networking by default. A task with user-authorized domains gets its own internal Docker network and a Squid proxy configured for those exact domains and ports 80/443. The proxy also rejects local and private destination ranges. Cancellation or completion removes the task container, proxy, network, and temporary volume.

The code container uses a non-root UID, read-only root filesystem, a single per-task writable volume, dropped capabilities, no-new-privileges, and CPU, memory, process, runtime, output, and artifact limits. Docker still shares the ECS Linux kernel, and access to the Docker socket is equivalent to host administration; these remain explicit limits of the design.

Bubblewrap was reviewed as a possible alternative. Its upstream documentation describes it as a low-level tool whose caller must define the security model and command-line restrictions. On this ECS, domain-authorized egress and process resource limits would still need separate host integration, while Docker Engine is already installed and provides the task lifecycle and cgroup limits required here. Keep the current Docker plan unless target-server testing exposes a concrete blocker.

## Data, deployment, and rollback

- Reuse the existing SQLite and object-storage volume without changing its layout.
- The production volume backup, SHA-256 manifests, old deployment configuration, and old DSH runtime state are retained under `/opt/xiaoqi-single-server/backups/genkit-cutover-20261010` with root-only directory and file permissions. The previous `xiaoqi-single-server:local` and `xiaoqi-dsh-manager:local` images remain available for rollback; historical image tags were removed.
- The old app and DSH containers, DSH Docker volume, staging project, staging volume, and temporary upload directories were removed after cutover checks passed. The old DSH volume is preserved as a restricted archive for rollback.
- The Genkit app and sandbox runner use the existing `xiaoqi-single-server_xiaoqi-data` volume. Its manifest matches the pre-cutover backup and still matches after restarting both production containers.
- The old admin hostname was `admin.47-76-60-77.sslip.io`; it is a dynamic `sslip.io` name rather than an AliDNS record. The new Caddy configuration has no DSH/admin route.
- Roll back by restoring `legacy-deploy-before-genkit.tgz` under `/opt/xiaoqi-single-server/current`, restoring `dsh-runtime-before-genkit.tgz` to a Docker volume named `xiaoqi-single-server_dsh-runtime`, and starting the prior Compose project. Keep the shared `xiaoqi-data` volume intact.

## Verification record

- [x] Production data archive SHA-256 and tar integrity verified; pre-cutover and post-restart store manifests match.
- [x] ECS Genkit build passed `dart analyze` with no issues and all 15 Dart tests passed.
- [x] The compatibility API routes note analysis, inline-image analysis, text rewriting, and conversation titles through authenticated `/v1/chat/completions`; provider keys and the default text model stay on the server.
- [x] The isolated ECS candidate container passed `/health`; unauthenticated `/v1/chat/completions` returned HTTP 401. Candidate tests used a fake generator and made no provider calls.
- [x] ECS sandbox runner and proxy images built; runner tests passed on ECS.
- [x] ECS sandbox checks passed for Python, JavaScript, TypeScript, default no-network, exact-domain allowlist, cancellation cleanup, and artifact return.
- [x] Production Genkit app, runner, and Caddy are healthy; public `/health` returned HTTP 200 after cutover and restart.
- [x] The production compatibility route is deployed; public unauthenticated `/v1/chat/completions` and `/mcp` both return HTTP 401. Server text defaults are `mimo-v2.5` and temperature `0.4`; the rollback image is present.
- [x] The shared store manifest still matches after deploying the compatibility route. The isolated candidate project, its test volume, and temporary build/upload files were removed.
- [x] Production runner executed a Python smoke task and removed its temporary container and volume.
- [x] Unauthenticated public `/mcp` returned HTTP 401; no DSH containers or staging containers remain.
- [ ] The Flutter source now sends note analysis, inline-image analysis, rewriting, and conversation-title requests to the Genkit route. The installed app binary has not been rebuilt or installed, and owner-session login, chat, skill sync, and MCP flows were not exercised on a device in this deployment turn.
- [ ] Image-provider generation/editing acceptance is deferred until after the architecture migration, as requested.

## References

- [Genkit Dart Agents](https://genkit.dev/docs/dart/agents/overview/) and [Genkit Dart package](https://pub.dev/packages/genkit/versions): runtime API and SDK requirements.
- [Docker Engine security](https://docs.docker.com/engine/security/), [Compose networking](https://docs.docker.com/compose/how-tos/networking/), and [resource constraints](https://docs.docker.com/engine/containers/resource_constraints): socket, network, and cgroup behavior.
- [Squid http_access](https://www.squid-cache.org/Doc/config/http_access/): per-task outbound access rules.
- [Bubblewrap upstream README](https://github.com/containers/bubblewrap/blob/main/README.md): caller-defined sandbox policy.
