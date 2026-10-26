#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="/opt/xiaoqi-single-server"
# Test roots are accepted only inside a dedicated temporary directory.
if [[ "${XIAOQI_DEPLOY_TEST:-}" == 1 ]]; then
  [[ "${XIAOQI_DEPLOY_ROOT:-}" == /tmp/xiaoqi-deploy-test-* ]] || exit 2
  ROOT="$XIAOQI_DEPLOY_ROOT"
fi
CURRENT="$ROOT/current"
CONFIG="$ROOT/config/single-server.env"
RESTORE_ROOT="$ROOT/restore"
LATEST="$RESTORE_ROOT/latest-good"
NEXT="$RESTORE_ROOT/next"
VOLUME="xiaoqi-single-server_xiaoqi-data"

LOCAL_IMAGES=(
  "xiaoqi-genkit-server:local"
  "xiaoqi-sandbox-runner:local"
  "xiaoqi-code-sandbox:local"
  "xiaoqi-sandbox-proxy:local"
)

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_layout() {
  [[ "$ROOT" == "/opt/xiaoqi-single-server" || "${XIAOQI_DEPLOY_TEST:-}" == 1 ]] || die "unsafe deployment root"
  [[ -d "$CURRENT/deploy" ]] || die "current deployment not found"
  mkdir -p "$ROOT/config" "$RESTORE_ROOT"
  if [[ ! -f "$CONFIG" ]]; then
    [[ -f "$CURRENT/deploy/single-server.env" ]] || die "server environment file not found"
    install -m 600 "$CURRENT/deploy/single-server.env" "$CONFIG"
  fi
  ln -sfn "$CONFIG" "$CURRENT/deploy/single-server.env"
}

compose() {
  docker compose \
    -f "$CURRENT/deploy/compose.yaml" \
    --env-file "$CONFIG" \
    "$@"
}

wait_healthy() {
  local deadline=$((SECONDS + 120))
  local service container status public_host
  for service in app sandbox-runner; do
    container="$(compose ps -q "$service")"
    [[ -n "$container" ]] || return 1
    while (( SECONDS < deadline )); do
      status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container" 2>/dev/null || true)"
      [[ "$status" == "healthy" ]] && break
      [[ "$status" == "unhealthy" || "$status" == "exited" || "$status" == "dead" ]] && return 1
      sleep 2
    done
    [[ "$status" == "healthy" ]] || return 1
  done
  curl --fail --silent --show-error --max-time 10 http://127.0.0.1:8080/health >/dev/null 2>&1 || \
    docker exec "$(compose ps -q app)" curl --fail --silent http://127.0.0.1:8080/health >/dev/null
  public_host="$(grep -m1 '^XIAOQI_PUBLIC_HOST=' "$CONFIG" | cut -d= -f2- | tr -d '"\r' || true)"
  if [[ -n "$public_host" && "$public_host" != "localhost" ]]; then
    [[ "$public_host" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
    curl --fail --silent --show-error --max-time 15 "https://$public_host/health" >/dev/null
  fi
}

remove_tree() {
  local target="$1"
  case "$target" in
    "$NEXT"|"$LATEST"|"$ROOT/staging/"*) rm -rf -- "$target" ;;
    *) die "refusing to remove unsafe path: $target" ;;
  esac
}

clear_staging() {
  local staging="$ROOT/staging"
  [[ "$staging" == "$ROOT/staging" ]] || die "unsafe staging path"
  mkdir -p "$staging"
  find "$staging" -mindepth 1 -maxdepth 1 -type d -exec rm -rf -- {} +
}

tag_images() {
  local suffix="$1"
  local image base
  for image in "${LOCAL_IMAGES[@]}"; do
    docker image inspect "$image" >/dev/null
    base="${image%:local}"
    docker tag "$image" "$base:$suffix"
  done
}

retag_to_local() {
  local suffix="$1"
  local image base
  for image in "${LOCAL_IMAGES[@]}"; do
    base="${image%:local}"
    docker image inspect "$base:$suffix" >/dev/null || return 1
    docker tag "$base:$suffix" "$image" || return 1
  done
}

remove_image_tags() {
  local suffix="$1"
  local image base
  for image in "${LOCAL_IMAGES[@]}"; do
    base="${image%:local}"
    docker image rm "$base:$suffix" >/dev/null 2>&1 || true
  done
}

write_store_manifest() {
  local output_dir="$1"
  local deploy_dir="$2"
  cp "$deploy_dir/verify_store.py" "$output_dir/verify_store.py"
  # SQLite mode=ro protects database contents, but WAL readers must be able to
  # create transient shared-memory sidecars after the application has stopped.
  docker run --rm \
    -v "$VOLUME:/data" \
    -v "$deploy_dir:/deploy:ro" \
    -v "$output_dir:/backup" \
    python:3.12-slim \
    python /deploy/verify_store.py --root /data --output /backup/store.json
}

compare_store_manifest() {
  local expected_dir="$1"
  local catalog_options=()
  [[ "${2:-}" != with-catalog ]] || catalog_options=(--catalog-changes /backup/catalog-changes.json)
  local verifier=/deploy/verify_store.py
  [[ ! -f "$expected_dir/verify_store.py" ]] || verifier=/backup/verify_store.py
  docker run --rm \
    -v "$VOLUME:/data" \
    -v "$CURRENT/deploy:/deploy:ro" \
    -v "$expected_dir:/backup:ro" \
    python:3.12-slim \
    python "$verifier" --root /data --compare /backup/store.json "${catalog_options[@]}" >/dev/null
}

backup_data() {
  local output_dir="$1"
  docker run --rm \
    -v "$VOLUME:/data:ro" \
    -v "$output_dir:/backup" \
    alpine:3.22 \
    sh -c 'tar -czf /backup/data.tgz -C /data .'
}

restore_data() {
  local input_dir="$1"
  [[ -f "$input_dir/data.tgz" ]] || die "restore data archive is missing"
  docker run --rm \
    -v "$VOLUME:/data" \
    -v "$input_dir:/backup:ro" \
    alpine:3.22 \
    sh -c 'find /data -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + && tar -xzf /backup/data.tgz -C /data'
}

install_source() {
  local source_dir="$1"
  local replacement="$ROOT/staging/install-$$"
  [[ -f "$source_dir/genkit_server/pubspec.yaml" ]] || die "release is missing genkit_server/pubspec.yaml"
  [[ -f "$source_dir/deploy/compose.yaml" ]] || die "release is missing deploy/compose.yaml"
  remove_tree "$replacement"
  mkdir -p "$replacement" || return 1
  cp -a "$source_dir/genkit_server" "$replacement/genkit_server" || return 1
  cp -a "$source_dir/deploy" "$replacement/deploy" || return 1
  if [[ -f "$source_dir/.xiaoqi-release" ]]; then
    cp "$source_dir/.xiaoqi-release" "$replacement/.xiaoqi-release" || return 1
  fi
  if [[ -f "$source_dir/.xiaoqi-artifact.json" ]]; then
    cp "$source_dir/.xiaoqi-artifact.json" "$replacement/.xiaoqi-artifact.json" || return 1
  fi
  rm -f "$replacement/deploy/single-server.env"
  ln -s "$CONFIG" "$replacement/deploy/single-server.env" || return 1
  if [[ -d "$CURRENT" ]]; then
    mv "$CURRENT" "$ROOT/staging/old-current-$$" || return 1
  fi
  mv "$replacement" "$CURRENT" || return 1
  remove_tree "$ROOT/staging/old-current-$$"
}

restore_source() {
  local restore_dir="$1"
  local unpack="$ROOT/staging/restore-$$"
  [[ -f "$restore_dir/source.tgz" ]] || die "restore source archive is missing"
  remove_tree "$unpack"
  mkdir -p "$unpack" || return 1
  tar -xzf "$restore_dir/source.tgz" -C "$unpack" || return 1
  install_source "$unpack" || return 1
  remove_tree "$unpack"
}

rollback_from() {
  local restore_dir="$1"
  local image_suffix="$2"
  local restore_data_flag="$3"
  set +e
  compose --profile https stop app sandbox-runner >/dev/null 2>&1
  set -e
  if [[ -f "$restore_dir/images.json" ]]; then
    python3 - "$restore_dir/images.json" <<'PY' || return 1
import json, subprocess, sys
for image in json.load(open(sys.argv[1])):
    subprocess.run(['docker', 'tag', image['Id'], image['XiaoqiLocalTag']], check=True)
PY
  else
    retag_to_local "$image_suffix" || return 1
  fi
  restore_source "$restore_dir" || return 1
  if [[ "$restore_data_flag" == "yes" ]]; then
    restore_data "$restore_dir" || return 1
  fi
  compose --profile https up -d --no-build --pull never --remove-orphans app sandbox-runner caddy || return 1
  wait_healthy || die "automatic rollback ran, but restored service is not healthy"
  if [[ "$restore_data_flag" == "yes" ]]; then
    compare_store_manifest "$restore_dir" || return 1
  fi
  leave_maintenance || return 1
  phase ROLLBACK_VERIFIED
}

phase() {
  printf '%s PHASE=%s\n' "$(date -u +%FT%TZ)" "$1"
}

enter_maintenance() {
  local host
  host="$(grep -m1 '^XIAOQI_PUBLIC_HOST=' "$CONFIG" | cut -d= -f2- | tr -d '"\r')"
  [[ "$host" =~ ^[A-Za-z0-9.-]+$ ]] || die "invalid public hostname"
  # Allow health probes, but hold new writes until data verification commits.
  compose exec -T caddy caddy reload --config - --adapter caddyfile <<EOF
$host {
  handle /health {
    reverse_proxy app:8080
  }
  handle {
    respond "Service updating. Please retry shortly." 503
  }
}
EOF
}

leave_maintenance() {
  compose exec -T caddy caddy reload --config - --adapter caddyfile < "$CURRENT/deploy/Caddyfile.docker"
}

preflight() {
  phase PREFLIGHT
  local tool available_kb memory_kb inodes data_kb
  for tool in docker curl tar sha256sum python3 flock timeout df; do
    command -v "$tool" >/dev/null || die "required tool missing: $tool"
  done
  docker info >/dev/null
  [[ "$(uname -m)" == x86_64 ]] || die "release requires x86_64"
  available_kb="$(df -Pk "$ROOT" | awk 'NR==2 {print $4}')"
  inodes="$(df -Pi "$ROOT" | awk 'NR==2 {print $4}')"
  memory_kb="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"
  data_kb="$(docker run --rm -v "$VOLUME:/data:ro" alpine:3.22 du -sk /data | awk '{print $1}')"
  (( available_kb > 6 * 1024 * 1024 + 2 * data_kb )) || die "not enough disk for images and two data snapshots"
  (( inodes > 10000 )) || die "not enough free inodes"
  (( memory_kb > 384 * 1024 )) || die "less than 384 MiB available memory"
  require_layout
  wait_healthy || die "current service is not healthy; refusing to deploy"
  printf 'PREFLIGHT_OK free_kib=%s available_memory_kib=%s\n' "$available_kb" "$memory_kb"
}

verify_loaded_images() {
  python3 - "$1" <<'PY'
import json, subprocess, sys
manifest = json.load(open(sys.argv[1]))
for image in manifest['images']:
    actual = json.loads(subprocess.check_output(['docker', 'inspect', image['tag']]))[0]
    if (actual['Id'], actual['Os'], actual['Architecture']) != (image['id'], image['os'], image['architecture']):
        raise SystemExit('Loaded image does not match CI manifest')
print('IMAGE_IDENTITIES_VERIFIED')
PY
}

verify_public_release() {
  local public_host body
  public_host="$(grep -m1 '^XIAOQI_PUBLIC_HOST=' "$CONFIG" | cut -d= -f2- | tr -d '"\r')"
  [[ "$public_host" =~ ^[A-Za-z0-9.-]+$ ]] || die "invalid public hostname"
  body="$(curl --fail --silent --show-error --max-time 20 "https://$public_host/health")"
  python3 - "$body" "$1" "$2" <<'PY'
import json, sys
h = json.loads(sys.argv[1])
if (h.get('status'), h.get('release_id'), h.get('api_contract_version')) != ('ok', sys.argv[2], sys.argv[3]):
    raise SystemExit('Public release/contract mismatch')
print('PUBLIC_RELEASE_VERIFIED')
PY
}

cleanup_success() {
  phase CLEANUP
  clear_staging
  # Only this project's tags; retain the running images and one restore point.
  local image tag
  for image in "${LOCAL_IMAGES[@]}"; do
    while IFS= read -r tag; do
      [[ "$tag" == "${image%:local}:local" || "$tag" == "${image%:local}:restore" ]] && continue
      docker image rm "$tag" >/dev/null 2>&1 || true
    done < <(docker image ls --format '{{.Repository}}:{{.Tag}}' "${image%:local}" | sort -u)
  done
  docker image prune -f >/dev/null || true
  docker builder prune -af >/dev/null || true
  local directory
  for directory in "$ROOT"/incoming/*; do
    [[ -d "$directory" && "$directory" != "$ROOT/incoming/$DEPLOY_RELEASE_ID" ]] || continue
    # Never delete another controller's active upload or download.
    if [[ -f "$directory/result" || ! -e "$directory/started" ]]; then
      find "$directory" -maxdepth 0 -mmin +120 -exec rm -rf -- {} +
    fi
  done
  # Keep seven deployment diagnostics, never an unbounded log directory.
  find "$ROOT/logs" -maxdepth 1 -name '*.log' -type f -printf '%T@ %p\n' | sort -nr | tail -n +8 | cut -d' ' -f2- | xargs -r rm -f --
}

cleanup_candidate_runner() {
  local resource
  docker rm -f xiaoqi-curated-release-probe >/dev/null 2>&1 || true
  if [[ -n "${DEPLOY_CANDIDATE_RUNNER:-}" ]]; then
    docker rm -f "$DEPLOY_CANDIDATE_RUNNER" >/dev/null 2>&1 || true
  fi
  # This namespace belongs only to the deployment probe, never production tasks.
  for resource in $(docker ps -aq --filter label=com.xiaoqi.release-probe-sandbox=true); do
    [[ "$resource" =~ ^[a-f0-9]+$ ]] && docker rm -f "$resource" >/dev/null || true
  done
  for resource in $(docker network ls -q --filter label=com.xiaoqi.release-probe-sandbox=true); do
    [[ "$resource" =~ ^[a-f0-9]+$ ]] && docker network rm "$resource" >/dev/null || true
  done
  for resource in $(docker volume ls -q --filter label=com.xiaoqi.release-probe-sandbox=true); do
    [[ "$resource" =~ ^xq-code-[a-zA-Z0-9_-]+$ ]] && docker volume rm "$resource" >/dev/null || true
  done
}

start_candidate_runner() {
  local commit="$1" runner_token attempt
  runner_token="$(python3 - "$CONFIG" <<'PY'
import sys
from pathlib import Path
for line in Path(sys.argv[1]).read_text().splitlines():
    key, sep, value = line.partition('=')
    if sep and key.strip() == 'SANDBOX_RUNNER_TOKEN':
        print(value.strip())
        break
PY
)"
  [[ -n "$runner_token" ]] || die "sandbox runner token missing"
  DEPLOY_CANDIDATE_RUNNER="xiaoqi-probe-runner-$DEPLOY_RELEASE_ID"
  SANDBOX_RUNNER_TOKEN="$runner_token" docker run --detach --rm \
    --name "$DEPLOY_CANDIDATE_RUNNER" --memory=384m --cpus=0.2 \
    --network xiaoqi-single-server_sandbox-control \
    --label com.xiaoqi.release-probe-sandbox=true \
    --volume /var/run/docker.sock:/var/run/docker.sock:ro \
    --env SANDBOX_RUNNER_TOKEN \
    --env XIAOQI_SANDBOX_OWNER_LABEL=com.xiaoqi.release-probe-sandbox \
    --env "XIAOQI_SANDBOX_IMAGE=xiaoqi-code-sandbox:build-$commit" \
    --env "XIAOQI_SANDBOX_PROXY_IMAGE=xiaoqi-sandbox-proxy:build-$commit" \
    "xiaoqi-sandbox-runner:build-$commit" >/dev/null
  unset runner_token
  for attempt in {1..30}; do
    if docker exec "$DEPLOY_CANDIDATE_RUNNER" python -c \
      'import urllib.request; urllib.request.urlopen("http://127.0.0.1:8090/health", timeout=2).close()' >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  die "candidate sandbox runner failed health check"
}

deployment_exit() {
  local rc=$?
  trap - EXIT INT TERM
  cleanup_candidate_runner
  docker rm -f xiaoqi-release-probe >/dev/null 2>&1 || true
  if (( rc != 0 )); then
    phase DEPLOY_FAILED
    if [[ "$DEPLOY_ROLLBACK_READY" == yes ]]; then
      if [[ "$DEPLOY_ACTIVATION_STARTED" == yes ]]; then
        if ! (set -Eeuo pipefail; rollback_from "$DEPLOY_RESTORE_DIR" rollback-next "$DEPLOY_DATA_SAVED"); then
          printf 'ROLLBACK_FAILED: recovery files retained at %s\n' "$DEPLOY_RESTORE_DIR" >&2
          exit 70
        fi
      else
        retag_to_local rollback-next || exit 70
        if [[ "$DEPLOY_MAINTENANCE" == yes ]]; then leave_maintenance || exit 70; fi
      fi
      remove_image_tags rollback-next
    fi
    remove_tree "$NEXT"
    remove_tree "$DEPLOY_STAGE"
  fi
  exit "$rc"
}

recover_pending() {
  [[ -d "$NEXT" ]] || return 0
  phase RECOVER_INTERRUPTED_DEPLOYMENT
  [[ -f "$NEXT/source.tgz" && -f "$NEXT/rollback-ready" ]] || die "incomplete recovery snapshot; refusing to replace it"
  if [[ -f "$NEXT/activation-started" ]]; then
    local data_saved=no
    [[ ! -f "$NEXT/data-saved" ]] || data_saved=yes
    enter_maintenance
    rollback_from "$NEXT" rollback-next "$data_saved"
  else
    retag_to_local rollback-next
    wait_healthy || die "interrupted deployment recovery is not healthy"
  fi
  remove_image_tags rollback-next
  remove_tree "$NEXT"
}

deploy_release() {
  local archive="$1"
  local release_id="$2"
  local expected_sha="$3"
  local commit="$4" product="$5" contract="$6"
  local stage="$ROOT/staging/$release_id"
  DEPLOY_ACTIVATION_STARTED="no"
  DEPLOY_DATA_SAVED="no"
  DEPLOY_STAGE="$stage"
  DEPLOY_RELEASE_ID="$release_id"
  DEPLOY_ROLLBACK_READY="no"
  DEPLOY_RESTORE_DIR="$NEXT"
  DEPLOY_MAINTENANCE=no

  [[ "$release_id" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid release id"
  [[ -f "$archive" ]] || die "release archive not found"
  [[ "$(sha256sum "$archive" | awk '{print $1}')" == "$expected_sha" ]] || die "release archive checksum mismatch"
  require_layout
  recover_pending
  preflight

  clear_staging
  mkdir -p "$NEXT" "$stage"
  trap deployment_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  phase VERIFY_ARTIFACT
  python3 "$(dirname "$0")/release_artifact.py" unpack --archive "$archive" --output "$stage" --commit "$commit" --product "$product" --contract "$contract"
  tar --exclude='./deploy/single-server.env' -czf "$NEXT/source.tgz" -C "$CURRENT" .
  tag_images rollback-next
  python3 - "$NEXT/images.json" "${LOCAL_IMAGES[@]}" <<'PY'
import json, subprocess, sys
images = []
for tag in sys.argv[2:]:
    image = json.loads(subprocess.check_output(['docker', 'inspect', tag]))[0]
    image['XiaoqiLocalTag'] = tag
    images.append(image)
with open(sys.argv[1], 'w') as stream:
    json.dump(images, stream)
PY
  DEPLOY_ROLLBACK_READY="yes"
  touch "$NEXT/rollback-ready"
  phase LOAD_PREBUILT_IMAGES
  timeout --kill-after=60s 600 docker load --input "$stage/images.tar.gz"
  verify_loaded_images "$stage/manifest.json"
  local image
  docker run --rm --network none --entrypoint sh "xiaoqi-code-sandbox:build-$commit" \
    -ec 'command -v xelatex >/dev/null && kpsewhich xeCJK.sty >/dev/null && fc-match "Noto Sans CJK SC" | grep -qi "Noto Sans CJK SC"' \
    || die "sandbox image is missing the required Chinese LaTeX toolchain"

  # Exercise the new runtime with synthetic data before touching the healthy
  # service or its persistent volume. A failure uses the existing rollback trap.
  phase RUNTIME_PROBE
  start_candidate_runner "$commit"
  timeout --kill-after=30s 600 docker run --rm --name xiaoqi-release-probe --memory=768m --cpus=1 --env-file "$CONFIG" \
    --entrypoint /app/bin/verify_capability_chain "xiaoqi-genkit-server:build-$commit"
  timeout --kill-after=30s 900 docker run --rm --name xiaoqi-curated-release-probe --memory=768m --cpus=1 --env-file "$CONFIG" \
    --network xiaoqi-single-server_default --network xiaoqi-single-server_sandbox-control \
    --env "SANDBOX_RUNNER_URL=http://$DEPLOY_CANDIDATE_RUNNER:8090" \
    --entrypoint /app/bin/verify_official_catalog "xiaoqi-genkit-server:build-$commit"
  cleanup_candidate_runner

  phase HOLD_WRITES
  DEPLOY_MAINTENANCE=yes
  enter_maintenance
  DEPLOY_ACTIVATION_STARTED="yes"
  touch "$NEXT/activation-started"
  phase BACKUP_DATA
  compose stop app
  backup_data "$NEXT"
  write_store_manifest "$NEXT" "$stage/source/deploy"
  DEPLOY_DATA_SAVED="yes"
  touch "$NEXT/data-saved"

  phase SEED_OFFICIAL_CATALOG
  docker run --rm --network none -v "$VOLUME:/var/lib/xiaoqi" \
    --entrypoint /app/bin/server "xiaoqi-genkit-server:build-$commit" \
    --seed-official-catalog >"$NEXT/catalog-changes.json"

  phase ACTIVATE
  for image in "${LOCAL_IMAGES[@]}"; do
    docker tag "${image%:local}:build-$commit" "$image"
  done
  install_source "$stage/source"
  cp "$stage/manifest.json" "$CURRENT/.xiaoqi-artifact.json"
  printf '%s\n' "$release_id" > "$CURRENT/.xiaoqi-release"
  compose --profile https up -d --no-build --pull never --remove-orphans app sandbox-runner caddy
  phase VERIFY_HEALTH_AND_DATA
  wait_healthy
  compare_store_manifest "$NEXT" with-catalog
  verify_public_release "$product" "$contract"

  remove_tree "$LATEST"
  mv "$NEXT" "$LATEST"
  DEPLOY_RESTORE_DIR="$LATEST"
  printf '%s\n' "$release_id" > "$LATEST/replaced-by-release"
  remove_image_tags restore
  local base
  for image in "${LOCAL_IMAGES[@]}"; do
    base="${image%:local}"
    docker tag "$base:rollback-next" "$base:restore"
  done
  phase RESUME_TRAFFIC
  leave_maintenance
  remove_image_tags rollback-next
  trap - EXIT
  cleanup_success
  printf 'DEPLOY_OK release=%s rollback=latest-good\n' "$release_id"
}

manual_rollback() {
  require_layout
  [[ -d "$LATEST" ]] || die "no latest-good restore point"
  enter_maintenance
  rollback_from "$LATEST" restore yes
  printf 'ROLLBACK_OK source=latest-good\n'
}

show_status() {
  require_layout
  printf 'current_release=%s\n' "$(cat "$CURRENT/.xiaoqi-release" 2>/dev/null || printf unknown)"
  printf 'current_health='
  if wait_healthy; then printf 'healthy\n'; else printf 'unhealthy\n'; fi
  if [[ -d "$LATEST" ]]; then
    printf 'restore_point=latest-good\n'
    printf 'restore_data=%s\n' "$(test -f "$LATEST/data.tgz" && printf present || printf missing)"
  else
    printf 'restore_point=missing\n'
  fi
}

mkdir -p "$ROOT"
if [[ "${1:-}" != status ]]; then
  exec 9>"$ROOT/.deploy.lock"
  flock -n 9 || die "another deployment is already running"
fi

case "${1:-}" in
  deploy)
    [[ $# -eq 7 ]] || die "usage: $0 deploy ARCHIVE RELEASE_ID SHA256 COMMIT PRODUCT CONTRACT"
    deploy_release "$2" "$3" "$4" "$5" "$6" "$7"
    ;;
  preflight)
    preflight
    ;;
  rollback)
    [[ $# -eq 1 ]] || die "usage: $0 rollback"
    manual_rollback
    ;;
  status)
    [[ $# -eq 1 ]] || die "usage: $0 status"
    show_status
    ;;
  *)
    die "usage: $0 {deploy ARCHIVE RELEASE_ID SHA256|rollback|status}"
    ;;
esac
