#!/usr/bin/env bash
# Tests for backup.sh and restore.sh. Plain bash, everything happens in a temp dir.
#   tests/run-tests.sh
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BACKUP="${HERE}/backup.sh"
RESTORE="${HERE}/restore.sh"
ROOT=$(mktemp -d)
trap 'chmod -R u+rwX "${ROOT}" 2>/dev/null; rm -rf -- "${ROOT}"' EXIT

pass=0
fail=0
check() { # check "description" command...
  local desc="$1"; shift
  if "$@"; then pass=$((pass + 1)); printf 'ok    %s\n' "${desc}"
  else fail=$((fail + 1)); printf 'FAIL  %s\n' "${desc}"; fi
}
status_is() { # status_is EXPECTED command...
  local want="$1"; shift
  "$@" >/dev/null 2>&1 </dev/null
  local rc=$?
  [[ "${rc}" == "${want}" ]] || { echo "      expected exit ${want}, got ${rc}: $*"; return 1; }
}
count_backups() { find "${DEST}" -maxdepth 1 -name 'data-*.tar.gz' | wc -l | tr -d ' '; }

# Sample data: nested dirs, spaces, an empty file, an empty dir, a symlink, a "cache" to exclude.
SRC="${ROOT}/data"
DEST="${ROOT}/backups"
mkdir -p "${SRC}/app/config" "${SRC}/empty dir" "${SRC}/cache"
echo "hello" >"${SRC}/app/readme.txt"
echo "key=value" >"${SRC}/app/config/app.env"
printf 'spaces' >"${SRC}/app/file with spaces.txt"
: >"${SRC}/app/empty.txt"
head -c 200000 /dev/urandom >"${SRC}/app/blob.bin"
ln -s readme.txt "${SRC}/app/link-to-readme"
echo "tmp" >"${SRC}/cache/skip.me"

# --- backups and rotation ---
for ts in 20260101T000000Z 20260102T000000Z 20260103T000000Z; do
  BACKUP_TIMESTAMP="${ts}" "${BACKUP}" -s "${SRC}" -d "${DEST}" -k 2 -e './cache/*' -l "${ROOT}/backup.log" 2>/dev/null
done
check "three runs with -k 2 keep two backups" test "$(count_backups)" = 2
check "oldest backup rotated (archive, checksum and manifest)" \
  test ! -e "${DEST}/data-20260101T000000Z.tar.gz" -a ! -e "${DEST}/data-20260101T000000Z.tar.gz.sha256" -a ! -e "${DEST}/data-20260101T000000Z.manifest"
LATEST="${DEST}/data-20260103T000000Z.tar.gz"
check "checksum file is valid" bash -c "cd '${DEST}' && sha256sum --quiet -c data-20260103T000000Z.tar.gz.sha256"
check "excluded path is not in the archive" bash -c "! tar -tzf '${LATEST}' | grep -q skip.me"
check "empty dir is in the archive" bash -c "tar -tzf '${LATEST}' | grep -q 'empty dir/'"
check "log file written" grep -q "backup ok" "${ROOT}/backup.log"
check "no temp work dirs left" test -z "$(find "${DEST}" -maxdepth 1 -name '.work.*')"

# --- restore ---
check "restore -V verifies" status_is 0 "${RESTORE}" -a "${LATEST}" -V
check "restore into empty dir" status_is 0 "${RESTORE}" -a "${LATEST}" -t "${ROOT}/restored"
check "restored tree equals source (minus excludes)" diff -r --no-dereference -x cache "${SRC}" "${ROOT}/restored"
check "symlink restored as a symlink" test -L "${ROOT}/restored/app/link-to-readme"
check "restore refuses a non-empty target" status_is 1 "${RESTORE}" -a "${LATEST}" -t "${ROOT}/restored"
check "restore -f overwrites" status_is 0 "${RESTORE}" -a "${LATEST}" -t "${ROOT}/restored" -f

# --- corruption is detected ---
cp "${LATEST}" "${ROOT}/corrupt.tar.gz"
cp "${LATEST}.sha256" "${ROOT}/corrupt.tar.gz.sha256"
sed -i 's/data-20260103T000000Z.tar.gz/corrupt.tar.gz/' "${ROOT}/corrupt.tar.gz.sha256"
printf 'X' | dd of="${ROOT}/corrupt.tar.gz" bs=1 seek=100 conv=notrunc 2>/dev/null
check "corrupted archive fails verification with exit 5" status_is 5 "${RESTORE}" -a "${ROOT}/corrupt.tar.gz" -V
cp "${LATEST}" "${ROOT}/badman.tar.gz"
(cd "${ROOT}" && sha256sum badman.tar.gz >badman.tar.gz.sha256)
sed 's/^[0-9a-f]\{8\}/00000000/' "${DEST}/data-20260103T000000Z.manifest" >"${ROOT}/badman.manifest"
check "file not matching the manifest fails with exit 5" status_is 5 "${RESTORE}" -a "${ROOT}/badman.tar.gz" -V
check "missing checksum file fails with exit 5" status_is 5 bash -c "cp '${LATEST}' '${ROOT}/nosum.tar.gz' && '${RESTORE}' -a '${ROOT}/nosum.tar.gz' -V"

# --- failures never rotate old backups ---
chmod 000 "${SRC}/app/readme.txt"
if [[ "$(id -u)" != 0 ]]; then
  check "unreadable source file fails the backup (exit 1)" status_is 1 env BACKUP_TIMESTAMP=20260104T000000Z "${BACKUP}" -s "${SRC}" -d "${DEST}" -k 1
  check "failed backup did not rotate existing backups" test "$(count_backups)" = 2
fi
chmod 644 "${SRC}/app/readme.txt"

# --- locking ---
if command -v flock >/dev/null 2>&1; then
  exec 8>"${DEST}/.data.lock"
  flock -n 8
  check "second run while locked exits 4" status_is 4 env BACKUP_TIMESTAMP=20260105T000000Z "${BACKUP}" -s "${SRC}" -d "${DEST}"
  exec 8>&-
fi

# --- usage errors ---
check "no args -> exit 2" status_is 2 "${BACKUP}"
check "bad -k -> exit 2" status_is 2 "${BACKUP}" -s "${SRC}" -d "${DEST}" -k zero
check "dest inside source -> exit 2" status_is 2 "${BACKUP}" -s "${SRC}" -d "${SRC}/backups"
check "missing source -> exit 1" status_is 1 "${BACKUP}" -s "${ROOT}/nope" -d "${DEST}"
check "same timestamp twice -> exit 1" status_is 1 env BACKUP_TIMESTAMP=20260103T000000Z "${BACKUP}" -s "${SRC}" -d "${DEST}"
check "restore without -t or -V -> exit 2" status_is 2 "${RESTORE}" -a "${LATEST}"
check "help -> exit 0" status_is 0 "${BACKUP}" -h

printf '\n%s passed, %s failed\n' "${pass}" "${fail}"
((fail == 0))
