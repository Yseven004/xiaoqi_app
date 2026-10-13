#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="/opt/xiaoqi-single-server"
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
  [[ "$ROOT" == "/opt/xiaoqi-single-server" ]] || die "unsafe deployment root"
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
  [[ "$staging" == "/opt/xiaoqi-single-server/staging" ]] || die "unsafe staging path"
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
    docker image inspect "$base:$suffix" >/dev/null
    docker tag "$base:$suffix" "$image"
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
  docker run --rm \
    -v "$VOLUME:/data:ro" \
    -v "$deploy_dir:/deploy:ro" \
    -v "$output_dir:/backup" \
    python:3.12-slim \
    python /deploy/verify_store.py --root /data --output /backup/store.json
}

compare_store_manifest() {
  local expected_dir="$1"
  docker run --rm \
    -v "$VOLUME:/data:ro" \
    -v "$CURRENT/deploy:/deploy:ro" \
    -v "$expected_dir:/backup:ro" \
    python:3.12-slim \
    python /deploy/verify_store.py --root /data --compare /backup/store.json >/dev/null
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
  mkdir -p "$replacement"
  cp -a "$source_dir/genkit_server" "$replacement/genkit_server"
  cp -a "$source_dir/deploy" "$replacement/deploy"
  rm -f "$replacement/deploy/single-server.env"
  ln -s "$CONFIG" "$replacement/deploy/single-server.env"
  if [[ -d "$CURRENT" ]]; then
    mv "$CURRENT" "$ROOT/staging/old-current-$$"
  fi
  mv "$replacement" "$CURRENT"
  remove_tree "$ROOT/staging/old-current-$$"
}

restore_source() {
  local restore_dir="$1"
  local unpack="$ROOT/staging/restore-$$"
  [[ -f "$restore_dir/source.tgz" ]] || die "restore source archive is missing"
  remove_tree "$unpack"
  mkdir -p "$unpack"
  tar -xzf "$restore_dir/source.tgz" -C "$unpack"
  install_source "$unpack"
  remove_tree "$unpack"
}

rollback_from() {
  local restore_dir="$1"
  local image_suffix="$2"
  local restore_data_flag="$3"
  set +e
  compose --profile https stop app sandbox-runner caddy >/dev/null 2>&1
  set -e
  retag_to_local "$image_suffix"
  restore_source "$restore_dir"
  if [[ "$restore_data_flag" == "yes" ]]; then
    restore_data "$restore_dir"
  fi
  compose --profile https up -d --remove-orphans app sandbox-runner caddy
  wait_healthy || die "automatic rollback ran, but restored service is not healthy"
}

deploy_release() {
  local archive="$1"
  local release_id="$2"
  local expected_sha="$3"
  local stage="$ROOT/staging/$release_id"
  DEPLOY_ACTIVATION_STARTED="no"
  DEPLOY_DATA_SAVED="no"
  DEPLOY_STAGE="$stage"

  [[ "$release_id" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid release id"
  [[ -f "$archive" ]] || die "release archive not found"
  [[ "$(sha256sum "$archive" | awk '{print $1}')" == "$expected_sha" ]] || die "release archive checksum mismatch"
  require_layout
  wait_healthy || die "current service is not healthy; refusing to deploy"

  clear_staging
  remove_tree "$NEXT"
  mkdir -p "$NEXT" "$stage"
  trap 'rc=$?; if (( rc != 0 )); then printf "DEPLOY_FAILED: restoring previous version\n" >&2; if [[ "$DEPLOY_ACTIVATION_STARTED" == "yes" ]]; then rollback_from "$NEXT" rollback-next "$DEPLOY_DATA_SAVED"; else retag_to_local rollback-next; fi; remove_image_tags rollback-next; remove_tree "$NEXT"; remove_tree "$DEPLOY_STAGE"; fi; exit $rc' EXIT

  tar --exclude='./deploy/single-server.env' -czf "$NEXT/source.tgz" -C "$CURRENT" .
  tag_images rollback-next
  tar -xzf "$archive" -C "$stage"
  [[ -f "$stage/genkit_server/pubspec.yaml" ]] || die "invalid release archive"
  ln -sfn "$CONFIG" "$stage/deploy/single-server.env"

  docker compose \
    -f "$stage/deploy/compose.yaml" \
    --env-file "$CONFIG" \
    --profile build-only \
    build app sandbox-runner sandbox-image sandbox-proxy-image

  DEPLOY_ACTIVATION_STARTED="yes"
  compose stop app
  backup_data "$NEXT"
  write_store_manifest "$NEXT" "$stage/deploy"
  DEPLOY_DATA_SAVED="yes"

  install_source "$stage"
  printf '%s\n' "$release_id" > "$CURRENT/.xiaoqi-release"
  compose --profile https up -d --remove-orphans app sandbox-runner caddy
  wait_healthy
  compare_store_manifest "$NEXT"

  remove_tree "$LATEST"
  mv "$NEXT" "$LATEST"
  printf '%s\n' "$release_id" > "$LATEST/replaced-by-release"
  remove_image_tags restore
  local image base
  for image in "${LOCAL_IMAGES[@]}"; do
    base="${image%:local}"
    docker tag "$base:rollback-next" "$base:restore"
  done
  remove_image_tags rollback-next
  trap - EXIT
  clear_staging || true
  docker image prune -f >/dev/null || true
  printf 'DEPLOY_OK release=%s rollback=latest-good\n' "$release_id"
}

manual_rollback() {
  require_layout
  [[ -d "$LATEST" ]] || die "no latest-good restore point"
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
exec 9>"$ROOT/.deploy.lock"
flock -n 9 || die "another deployment is already running"

case "${1:-}" in
  deploy)
    [[ $# -eq 4 ]] || die "usage: $0 deploy ARCHIVE RELEASE_ID SHA256"
    deploy_release "$2" "$3" "$4"
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
