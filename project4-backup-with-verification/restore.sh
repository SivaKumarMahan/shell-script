#!/usr/bin/env bash
# restore.sh - verify a backup made by backup.sh and restore it.
#
# Exit codes:
#   0  restored (or verified with -V)
#   1  restore failed (tar error, target not empty, ...)
#   2  usage error
#   3  missing dependency
#   5  verification failed (checksum or manifest mismatch)
set -euo pipefail

readonly SCRIPT_NAME="${0##*/}"

ARCHIVE=""
TARGET=""
VERIFY_ONLY=false
FORCE=false

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} -a ARCHIVE.tar.gz [-t TARGET_DIR] [-V] [-f] [-h]

Check the .sha256 next to the archive, then extract it and check every file
against the .manifest made at backup time.

Options:
  -a FILE   Archive created by backup.sh (required)
  -t DIR    Restore into DIR (required unless -V). Must be empty unless -f
  -V        Verify only: checksum + full test extract to a temp dir, then delete it
  -f        Allow restoring into a non-empty directory (files are overwritten)
  -h        Show this help

Exit codes: 0 ok, 1 restore failed, 2 usage, 3 missing tool, 5 verification failed.
EOF
}

log() { printf '%s [%s] %s: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${SCRIPT_NAME}" "${*:2}" >&2; }
die() { log ERROR "$1"; exit "${2:-1}"; }

TMP=""
trap '[[ -n "${TMP}" ]] && rm -rf -- "${TMP}"; true' EXIT

main() {
  local opt
  while getopts ':a:t:Vfh' opt; do
    case "${opt}" in
      a) ARCHIVE="${OPTARG}" ;;
      t) TARGET="${OPTARG}" ;;
      V) VERIFY_ONLY=true ;;
      f) FORCE=true ;;
      h) usage; exit 0 ;;
      :) printf '%s: option -%s needs a value\n' "${SCRIPT_NAME}" "${OPTARG}" >&2; exit 2 ;;
      *) printf '%s: unknown option -%s\n' "${SCRIPT_NAME}" "${OPTARG}" >&2; usage >&2; exit 2 ;;
    esac
  done
  [[ -n "${ARCHIVE}" ]] || { usage >&2; exit 2; }
  [[ "${VERIFY_ONLY}" == true || -n "${TARGET}" ]] || { printf '%s: -t is required (or use -V)\n' "${SCRIPT_NAME}" >&2; exit 2; }
  for c in tar sha256sum mktemp; do command -v "${c}" >/dev/null 2>&1 || die "missing command: ${c}" 3; done

  [[ -f "${ARCHIVE}" ]] || die "archive not found: ${ARCHIVE}"
  local dir file base
  dir=$(cd "$(dirname "${ARCHIVE}")" && pwd)
  file=$(basename "${ARCHIVE}")
  base="${file%.tar.gz}"

  # 1. Archive checksum.
  [[ -f "${dir}/${file}.sha256" ]] || die "checksum file missing: ${dir}/${file}.sha256" 5
  (cd "${dir}" && sha256sum --quiet -c "${file}.sha256") || die "checksum mismatch: ${file} is corrupt" 5
  log INFO "checksum ok: ${file}"

  # 2. Extract (to a temp dir for -V).
  if [[ "${VERIFY_ONLY}" == true ]]; then
    TMP=$(mktemp -d)
    TARGET="${TMP}"
  else
    mkdir -p -- "${TARGET}"
    if [[ "${FORCE}" != true && -n "$(ls -A -- "${TARGET}")" ]]; then
      die "target is not empty: ${TARGET} (use -f to overwrite)"
    fi
  fi
  tar -C "${TARGET}" --no-same-owner -xzf "${dir}/${file}" || die "extract failed"

  # 3. Per-file check against the manifest written at backup time.
  if [[ -f "${dir}/${base}.manifest" ]]; then
    (cd "${TARGET}" && sha256sum --quiet -c "${dir}/${base}.manifest") || die "restored files do not match the manifest" 5
    log INFO "manifest ok: $(wc -l <"${dir}/${base}.manifest" | tr -d ' ') file(s) match"
  else
    log WARN "no manifest found (${base}.manifest); only the archive checksum was checked"
  fi

  if [[ "${VERIFY_ONLY}" == true ]]; then
    log INFO "verify ok: ${file}"
  else
    log INFO "restored ${file} into ${TARGET}"
  fi
}

main "$@"
