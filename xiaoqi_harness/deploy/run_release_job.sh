#!/usr/bin/env bash
# Run independently of the Cloud Assistant connection; publish an atomic result.
set -Eeuo pipefail
umask 077
root=/opt/xiaoqi-single-server
release="${1:?release required}"
commit="${2:?commit required}"
product="${3:?product required}"
contract="${4:?contract required}"
[[ "$release" =~ ^[A-Za-z0-9._-]+$ && "$commit" =~ ^[a-f0-9]{40}$ && "$product" =~ ^[A-Za-z0-9._-]+$ && "$contract" =~ ^[0-9]+$ ]] || exit 2
incoming="$root/incoming/$release"
mkdir -p "$root/logs"
log="$root/logs/$release.log"
exec >"$log" 2>&1
chmod 600 "$log"
finish() {
  rc=$?
  trap - EXIT
  printf '%s\n' "$rc" > "$incoming/result.tmp"
  mv "$incoming/result.tmp" "$incoming/result"
  # The log is retained outside the upload directory, including on failure.
  rm -f "$incoming/download.conf" "$incoming/artifact.zip" "$incoming/release.tgz"
  exit "$rc"
}
trap finish EXIT
exec 8>"$root/.release-job.lock"
flock -n 8 || { printf 'Another release job is active\n'; exit 75; }
printf '%s PHASE=DOWNLOAD_ARTIFACT\n' "$(date -u +%FT%TZ)"
curl --fail --silent --show-error --proto '=https' --max-time 900 --retry 2 --config "$incoming/download.conf" --output "$incoming/artifact.zip"
rm -f "$incoming/download.conf"
python3 - "$incoming" <<'PY'
import pathlib, re, sys, zipfile
root = pathlib.Path(sys.argv[1])
with zipfile.ZipFile(root / 'artifact.zip') as archive:
    if set(archive.namelist()) != {'release.tgz', 'release.sha256'} or len(archive.infolist()) != 2:
        raise SystemExit('Unexpected artifact contents')
    if sum(i.file_size for i in archive.infolist()) > 8 * 1024**3:
        raise SystemExit('Artifact exceeds size limit')
    archive.extractall(root)
digest = (root / 'release.sha256').read_text().strip()
if not re.fullmatch('[a-f0-9]{64}', digest):
    raise SystemExit('Invalid release checksum')
PY
digest="$(cat "$incoming/release.sha256")"
timeout --signal=TERM --kill-after=300s 1800 \
  bash "$incoming/release_manager.sh" deploy "$incoming/release.tgz" "$release" "$digest" "$commit" "$product" "$contract"
# Install the verified manager only after the release succeeds.
install -m 700 "$incoming/release_manager.sh" "$root/release_manager.next"
mv "$root/release_manager.next" "$root/release_manager.sh"
install -m 600 "$incoming/release_artifact.py" "$root/release_artifact.py"
