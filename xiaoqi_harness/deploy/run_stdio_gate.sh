#!/usr/bin/env bash
# Runs on the isolated CI build runner; no production environment or paid APIs.
set -Eeuo pipefail
export SANDBOX_RUNNER_TOKEN
SANDBOX_RUNNER_TOKEN="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
cleanup() {
  local item
  docker rm -f xiaoqi-stdio-gate-probe xiaoqi-stdio-gate-runner >/dev/null 2>&1 || true
  for item in $(docker ps -aq --filter label=com.xiaoqi.ci-stdio-sandbox=true); do docker rm -f "$item" >/dev/null || true; done
  for item in $(docker network ls -q --filter label=com.xiaoqi.ci-stdio-sandbox=true); do docker network rm "$item" >/dev/null || true; done
  for item in $(docker volume ls -q --filter label=com.xiaoqi.ci-stdio-sandbox=true); do docker volume rm "$item" >/dev/null || true; done
  docker network rm xiaoqi-stdio-gate >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker network create xiaoqi-stdio-gate >/dev/null
docker run --detach --name xiaoqi-stdio-gate-runner --network xiaoqi-stdio-gate \
  --volume /var/run/docker.sock:/var/run/docker.sock:ro --env SANDBOX_RUNNER_TOKEN \
  --env XIAOQI_SANDBOX_OWNER_LABEL=com.xiaoqi.ci-stdio-sandbox \
  --env XIAOQI_SANDBOX_IMAGE=xiaoqi-code-sandbox:local \
  --env XIAOQI_SANDBOX_PROXY_IMAGE=xiaoqi-sandbox-proxy:local \
  xiaoqi-sandbox-runner:local >/dev/null
ready=no
for attempt in {1..30}; do
  if docker exec xiaoqi-stdio-gate-runner python3 -c 'import urllib.request; urllib.request.urlopen("http://127.0.0.1:8090/health",timeout=2).close()' >/dev/null 2>&1; then ready=yes; break; fi
  sleep 1
done
if [[ "$ready" != yes ]]; then docker logs --tail 80 xiaoqi-stdio-gate-runner; exit 1; fi
timeout --kill-after=30s 360 docker run --rm --name xiaoqi-stdio-gate-probe --network xiaoqi-stdio-gate \
  --env SANDBOX_RUNNER_TOKEN --env SANDBOX_RUNNER_URL=http://xiaoqi-stdio-gate-runner:8090 \
  --entrypoint /app/bin/verify_stdio_runtime xiaoqi-genkit-server:local
