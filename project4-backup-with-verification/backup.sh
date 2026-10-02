#!/usr/bin/env bash
# backup.sh - compressed backup of a directory with checksum, restore test and rotation.
#
# Steps:  lock -> file list + manifest -> tar.gz -> sha256 -> verify -> restore test -> rotate
# Old backups are rotated ONLY after the new one passed every check.
#
# Exit codes:
#   0  backup created and verified
#   1  backup failed (tar error, unreadable source, disk full, ...)
#   2  usage error
#   3  missing dependency
#   4  another backup of the same target is running (lock held)
#   5  verification or restore test failed (bad archive is kept as *.failed for analysis)
set -euo pipefail

readonly SCRIPT_NAME="${0##*/}"

SOURCE=""
DEST=""
KEEP=7
NAME=""
LOG_FILE=""
RESTORE_TEST=true
declare -a EXCLUDES=()

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} -s SOURCE_DIR -d BACKUP_DIR [options]

Create <BACKUP_DIR>/<NAME>-<UTC timestamp>.tar.gz with a .sha256 and a .manifest file,
verify it, test a restore, then delete old backups beyond KEEP.

Options:
  -s DIR        Directory to back up (required)
  -d DIR        Where backups are stored (required, created if missing)
  -k N          Number of backups to keep (default: ${KEEP})
  -n NAME       Backup name prefix (default: name of SOURCE_DIR)
  -e GLOB       Exclude paths matching GLOB, relative to SOURCE, e.g. './cache/*' (repeatable)
  -l FILE       Also append log lines to FILE
  -R            Skip the restore test (faster; checksum and gzip test still run)
  -h            Show this help

Exit codes: 0 ok, 1 backup failed, 2 usage, 3 missing tool, 4 locked, 5 verification failed.
EOF
}

log() {
  local line
  line="$(date -u +%Y-%m-%dT%H:%M:%SZ) [$1] ${SCRIPT_NAME}: ${*:2}"
  printf '%s\n' "${line}" >&2
  if [[ -n "${LOG_FILE}" ]]; then printf '%s\n' "${line}" >>"${LOG_FILE}"; fi
}
die() { log ERROR "$1"; exit "${2:-1}"; }

parse_args() {
  local opt
  while getopts ':s:d:k:n:e:l:Rh' opt; do
    case "${opt}" in
      s) SOURCE="${OPTARG}" ;;
      d) DEST="${OPTARG}" ;;
      k) KEEP="${OPTARG}" ;;
      n) NAME="${OPTARG}" ;;
      e) EXCLUDES+=("${OPTARG}") ;;
      l) LOG_FILE="${OPTARG}" ;;
      R) RESTORE_TEST=false ;;
      h) usage; exit 0 ;;
      :) printf '%s: option -%s needs a value\n' "${SCRIPT_NAME}" "${OPTARG}" >&2; exit 2 ;;
      *) printf '%s: unknown option -%s\n' "${SCRIPT_NAME}" "${OPTARG}" >&2; usage >&2; exit 2 ;;
    esac
  done
  shift $((OPTIND - 1))
  (($# == 0)) || { printf '%s: unexpected argument: %s\n' "${SCRIPT_NAME}" "$1" >&2; exit 2; }
  [[ -n "${SOURCE}" && -n "${DEST}" ]] || { usage >&2; exit 2; }
  [[ "${KEEP}" =~ ^[1-9][0-9]*$ ]] || { printf '%s: -k must be a positive integer\n' "${SCRIPT_NAME}" >&2; exit 2; }
  [[ -d "${SOURCE}" ]] || die "source directory not found: ${SOURCE}"
  SOURCE=$(cd "${SOURCE}" && pwd)
  NAME="${NAME:-$(basename "${SOURCE}")}"
  [[ "${NAME}" =~ ^[A-Za-z0-9._-]+$ ]] || { printf '%s: -n may only use letters, digits, . _ -\n' "${SCRIPT_NAME}" >&2; exit 2; }
}

check_deps() {
  local c
  for c in tar gzip sha256sum find sort xargs mktemp; do
    command -v "${c}" >/dev/null 2>&1 || die "missing command: ${c}" 3
  done
}

# Only one backup per target at a time (cron overlap, manual run during cron).
take_lock() {
  local lock="${DEST}/.${NAME}.lock"
  if command -v flock >/dev/null 2>&1; then
    exec 9>"${lock}"
    flock -n 9 || die "another backup of ${NAME} is running (lock: ${lock})" 4
  else
    # Portable fallback: mkdir is atomic.
    mkdir "${lock}.d" 2>/dev/null || die "another backup of ${NAME} is running (lock: ${lock}.d)" 4
    LOCK_DIR="${lock}.d"
  fi
}

WORK=""
LOCK_DIR=""
cleanup() {
  [[ -n "${WORK}" ]] && rm -rf -- "${WORK}"
  [[ -n "${LOCK_DIR}" ]] && rmdir -- "${LOCK_DIR}" 2>/dev/null
  return 0
}
trap cleanup EXIT

main() {
  parse_args "$@"
  check_deps
  mkdir -p -- "${DEST}"
  DEST=$(cd "${DEST}" && pwd)
  case "${DEST}/" in
    "${SOURCE}/"*) die "backup dir must not be inside the source dir" 2 ;;
  esac
  take_lock
  WORK=$(mktemp -d "${DEST}/.work.XXXXXX")

  # BACKUP_TIMESTAMP lets tests create several backups within one second.
  local ts base archive
  ts="${BACKUP_TIMESTAMP:-$(date -u +%Y%m%dT%H%M%SZ)}"
  base="${NAME}-${ts}"
  archive="${DEST}/${base}.tar.gz"
  [[ ! -e "${archive}" ]] || die "backup already exists: ${archive}"
  log INFO "backing up ${SOURCE} -> ${archive}"

  # 1. File list (NUL separated: safe for spaces/newlines) and a checksum manifest.
  local -a find_args=(. -mindepth 1)
  local g
  for g in ${EXCLUDES[@]+"${EXCLUDES[@]}"}; do find_args+=(-not -path "${g}"); done
  # Directories are listed too (tar runs with --no-recursion) so empty dirs and modes are kept.
  (cd "${SOURCE}" && find "${find_args[@]}" \( -type f -o -type l -o -type d \) -print0 | sort -z) >"${WORK}/files.list" ||
    die "could not list all source files (check permissions)"
  (cd "${SOURCE}" && find "${find_args[@]}" -type f -print0 | sort -z | xargs -0 -r sha256sum) >"${WORK}/manifest" ||
    die "could not read all source files (check permissions)"
  local count
  count=$(tr -cd '\0' <"${WORK}/files.list" | wc -c | tr -d ' ')
  log INFO "${count} entries to back up ($(wc -l <"${WORK}/manifest" | tr -d ' ') regular files)"

  # 2. Archive to a temp name; it only gets its final name after all checks pass.
  tar -C "${SOURCE}" --null --no-recursion -T "${WORK}/files.list" -czf "${WORK}/archive.tar.gz" ||
    die "tar failed"

  # 3. Checksum (file name only, so the backup dir can be moved or copied off-site).
  (cd "${WORK}" && sha256sum archive.tar.gz | sed "s|archive.tar.gz|${base}.tar.gz|") >"${WORK}/archive.sha256"

  # 4. Verify: gzip stream and tar index are readable.
  if ! gzip -t "${WORK}/archive.tar.gz" || ! tar -tzf "${WORK}/archive.tar.gz" >/dev/null; then
    mv -f -- "${WORK}/archive.tar.gz" "${archive}.failed"
    die "archive integrity check failed (kept ${archive}.failed)" 5
  fi

  # 5. Restore test: extract to a scratch dir and compare with the manifest.
  if [[ "${RESTORE_TEST}" == true ]]; then
    mkdir "${WORK}/restore"
    tar -C "${WORK}/restore" --no-same-owner -xzf "${WORK}/archive.tar.gz"
    if ! (cd "${WORK}/restore" && sha256sum --quiet -c "${WORK}/manifest"); then
      mv -f -- "${WORK}/archive.tar.gz" "${archive}.failed"
      die "restore test failed: restored files do not match the manifest (source changed during backup?)" 5
    fi
    log INFO "restore test passed ($(wc -l <"${WORK}/manifest" | tr -d ' ') file checksums match)"
  fi

  # 6. Publish: manifest and checksum first, archive last (atomic rename on the same filesystem).
  mv -f -- "${WORK}/manifest" "${DEST}/${base}.manifest"
  mv -f -- "${WORK}/archive.sha256" "${DEST}/${base}.tar.gz.sha256"
  mv -f -- "${WORK}/archive.tar.gz" "${archive}"
  (cd "${DEST}" && sha256sum --quiet -c "${base}.tar.gz.sha256") || die "checksum mismatch after move" 5
  log INFO "backup ok: ${archive} ($(du -h "${archive}" | cut -f1))"

  # 7. Rotate: keep the newest KEEP backups of this NAME. Names sort by time (UTC timestamp).
  local -a all=()
  mapfile -t all < <(find "${DEST}" -maxdepth 1 -type f -name "${NAME}-*.tar.gz" -printf '%f\n' | sort)
  local remove=$((${#all[@]} - KEEP)) i old
  for ((i = 0; i < remove; i++)); do
    old="${all[i]%.tar.gz}"
    rm -f -- "${DEST}/${old}.tar.gz" "${DEST}/${old}.tar.gz.sha256" "${DEST}/${old}.manifest"
    log INFO "rotated old backup ${old}.tar.gz"
  done
  log INFO "keeping $((${#all[@]} - (remove > 0 ? remove : 0))) backup(s) of ${NAME}"
}

main "$@"
