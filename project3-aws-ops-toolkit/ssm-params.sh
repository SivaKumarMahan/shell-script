#!/usr/bin/env bash
# ssm-params.sh - export, import and diff SSM Parameter Store paths.
#
# Secret handling:
#   - SecureString values are never printed unless you pass --show-secrets (diff only).
#   - Values are never put on a command line (they would show in 'ps'); put-parameter
#     reads them from a private temp file with --cli-input-json.
#   - Export files are created with mode 600 because they contain decrypted values.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<EOF
Usage:
  ${SCRIPT_NAME} export --path PATH --file FILE [--skip-secure] [--force]
  ${SCRIPT_NAME} import --path PATH --file FILE [--overwrite] [--kms-key-id ID] [--dry-run] [--yes]
  ${SCRIPT_NAME} diff   --left PATH --right PATH [--left-profile P] [--right-profile P]
                        [--left-region R] [--right-region R] [--show-secrets]

Commands:
  export   Write every parameter under PATH (recursive, decrypted) to a JSON file.
  import   Create/update parameters under PATH from a JSON file made by 'export'.
           Shows a plan first and asks before writing (skip the prompt with --yes).
  diff     Compare two paths, in the same or in different accounts/regions.

Options:
  --path PATH          Parameter path, for example /myapp/dev
  --file FILE          Export target / import source (JSON)
  --skip-secure        export: leave out SecureString parameters
  --force              export: overwrite FILE if it exists
  --overwrite          import: update parameters that already exist with a different value
  --kms-key-id ID      import: KMS key for SecureString (default: aws/ssm)
  --dry-run            import: show the plan, change nothing
  --yes                import: do not ask for confirmation
  --show-secrets       diff: print SecureString values (careful: terminal history, CI logs)
  --log-level LEVEL    debug|info|warn|error (default: info)
  -h, --help           Show this help

Environment: AWS_PROFILE, AWS_REGION, AWS_ENDPOINT_URL (e.g. LocalStack), LOG_LEVEL, LOG_FILE.

Exit codes: 0 ok / no differences, 1 error, 2 usage, 3 missing tool, 4 aborted,
            5 diff found differences.
EOF
}

# normalize_path /a/b/ -> /a/b (root "/" stays "/")
normalize_path() {
  local p="$1"
  [[ "${p}" == /* ]] || usage_error "parameter path must start with '/': ${p}"
  while [[ "${p}" != "/" && "${p}" == */ ]]; do p="${p%/}"; done
  printf '%s' "${p}"
}

# prefix_of /a/b -> "/a/b/" ; "/" -> "/"
prefix_of() {
  if [[ "$1" == "/" ]]; then printf '/'; else printf '%s/' "$1"; fi
}

# fetch_path PATH OUTFILE
# Writes [{name, type, value}] sorted by name; names are relative to PATH.
# The CLI follows NextToken pages for us. Output goes to a file, not to stdout.
fetch_path() {
  local path="$1" out="$2" raw
  raw="${out}.raw"
  log_info "reading parameters under ${path}"
  aws_cli ssm get-parameters-by-path --path "${path}" --recursive --with-decryption >"${raw}" ||
    die "get-parameters-by-path failed for ${path}"
  jq --arg prefix "$(prefix_of "${path}")" '
    [.Parameters[]? | {name: (.Name | ltrimstr($prefix)), type: .Type, value: .Value}]
    | sort_by(.name)' "${raw}" >"${out}"
  rm -f -- "${raw}"
  log_info "found $(jq length "${out}") parameter(s) under ${path}"
}

cmd_export() {
  local path="" file="" skip_secure=false force=false tmp
  while (($# > 0)); do
    case "$1" in
      --path) require_value "$1" "${2-}"; path="$2"; shift 2 ;;
      --file) require_value "$1" "${2-}"; file="$2"; shift 2 ;;
      --skip-secure) skip_secure=true; shift ;;
      --force) force=true; shift ;;
      *) usage_error "unknown option for export: $1" ;;
    esac
  done
  [[ -n "${path}" && -n "${file}" ]] || usage_error "export needs --path and --file"
  path=$(normalize_path "${path}")
  if [[ -e "${file}" && "${force}" != true ]]; then
    die "${file} already exists (use --force to overwrite)"
  fi

  check_aws_access
  make_tmpdir tmp
  fetch_path "${path}" "${tmp}/params.json"

  (
    umask 077
    jq --arg path "${path}" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson skip "${skip_secure}" '
      {source_path: $path, exported_at: $now,
       parameters: (if $skip then map(select(.type != "SecureString")) else . end)}' \
      "${tmp}/params.json" >"${file}.tmp"
    mv -f -- "${file}.tmp" "${file}"
  )
  chmod 600 -- "${file}"

  local total secure
  total=$(jq '.parameters | length' "${file}")
  secure=$(jq '[.parameters[] | select(.type == "SecureString")] | length' "${file}")
  log_info "exported ${total} parameter(s) (${secure} SecureString) from ${path} to ${file}"
  if ((secure > 0)); then
    log_warn "${file} contains decrypted secrets: keep it out of git and delete it when done"
  fi
}

cmd_import() {
  local path="" file="" overwrite=false kms_key="" tmp prefix
  while (($# > 0)); do
    case "$1" in
      --path) require_value "$1" "${2-}"; path="$2"; shift 2 ;;
      --file) require_value "$1" "${2-}"; file="$2"; shift 2 ;;
      --overwrite) overwrite=true; shift ;;
      --kms-key-id) require_value "$1" "${2-}"; kms_key="$2"; shift 2 ;;
      --dry-run) DRY_RUN=true; shift ;;
      --yes) ASSUME_YES=true; shift ;;
      *) usage_error "unknown option for import: $1" ;;
    esac
  done
  [[ -n "${path}" && -n "${file}" ]] || usage_error "import needs --path and --file"
  path=$(normalize_path "${path}")
  prefix=$(prefix_of "${path}")
  [[ -r "${file}" ]] || die "cannot read ${file}"
  jq -e '.parameters | type == "array" and all(.[]; (.name | type) == "string" and
          (.type | IN("String", "StringList", "SecureString")) and (.value | type) == "string")' \
    "${file}" >/dev/null 2>&1 || die "${file} is not a valid export file (expected {parameters: [{name, type, value}]})"

  check_aws_access
  make_tmpdir tmp
  fetch_path "${path}" "${tmp}/current.json"

  # Plan: one JSON object per line with action create | update | unchanged | skip.
  jq -c --arg prefix "${prefix}" --argjson overwrite "${overwrite}" \
    --slurpfile cur "${tmp}/current.json" '
    ($cur[0] | map({key: .name, value: .}) | from_entries) as $c
    | .parameters[] | . as $s | $c[$s.name] as $e
    | {name: ($prefix + .name), type, value,
       action: (if $e == null then "create"
                elif $e.type == $s.type and $e.value == $s.value then "unchanged"
                elif $overwrite then "update"
                else "skip" end)}' "${file}" >"${tmp}/plan.jsonl"

  # Show the plan without values.
  printf 'Plan for %s:\n' "${path}"
  jq -r '"  \(.action | ascii_upcase | . + "          " | .[0:10]) \(.name) (\(.type))"' "${tmp}/plan.jsonl"
  local creates updates skips unchanged
  creates=$(jq -s 'map(select(.action == "create")) | length' "${tmp}/plan.jsonl")
  updates=$(jq -s 'map(select(.action == "update")) | length' "${tmp}/plan.jsonl")
  skips=$(jq -s 'map(select(.action == "skip")) | length' "${tmp}/plan.jsonl")
  unchanged=$(jq -s 'map(select(.action == "unchanged")) | length' "${tmp}/plan.jsonl")
  printf 'Summary: %s to create, %s to update, %s unchanged, %s skipped\n' \
    "${creates}" "${updates}" "${unchanged}" "${skips}"
  if ((skips > 0)); then
    log_warn "${skips} parameter(s) already exist with a different value; use --overwrite to update them"
  fi

  if ((creates + updates == 0)); then
    log_info "nothing to change"
    return 0
  fi
  if [[ "${DRY_RUN}" == true ]]; then
    log_info "dry run: no changes made"
    return 0
  fi
  confirm "Apply ${creates} create(s) and ${updates} update(s) to ${path}?" || die "aborted by user" "${EXIT_ABORTED}"

  # Build put-parameter requests; the shell only sees them line by line (no argv exposure).
  jq -c --arg kms "${kms_key}" '
    select(.action == "create" or .action == "update")
    | {Name: .name, Value: .value, Type: .type, Overwrite: (.action == "update")}
      + (if .type == "SecureString" and $kms != "" then {KeyId: $kms} else {} end)' \
    "${tmp}/plan.jsonl" >"${tmp}/requests.jsonl"

  local line name failed=0 done_count=0
  while IFS= read -r line; do
    printf '%s' "${line}" >"${tmp}/request.json"
    name=$(jq -r .Name "${tmp}/request.json")
    if aws_cli ssm put-parameter --cli-input-json "file://${tmp}/request.json" >/dev/null; then
      log_info "wrote ${name}"
      done_count=$((done_count + 1))
    else
      log_error "failed to write ${name}"
      failed=$((failed + 1))
    fi
  done <"${tmp}/requests.jsonl"
  rm -f -- "${tmp}/request.json"

  log_info "import finished: ${done_count} written, ${failed} failed"
  ((failed == 0)) || exit "${EXIT_FAILURE}"
}

# fetch_side PATH PROFILE REGION OUTFILE: fetch with an optional per-side profile/region.
fetch_side() {
  (
    if [[ -n "$2" ]]; then export AWS_PROFILE="$2"; fi
    if [[ -n "$3" ]]; then export AWS_REGION="$3"; fi
    check_aws_access
    fetch_path "$1" "$4"
  )
}

cmd_diff() {
  local left="" right="" lprof="" rprof="" lreg="" rreg="" show=false tmp
  while (($# > 0)); do
    case "$1" in
      --left) require_value "$1" "${2-}"; left="$2"; shift 2 ;;
      --right) require_value "$1" "${2-}"; right="$2"; shift 2 ;;
      --left-profile) require_value "$1" "${2-}"; lprof="$2"; shift 2 ;;
      --right-profile) require_value "$1" "${2-}"; rprof="$2"; shift 2 ;;
      --left-region) require_value "$1" "${2-}"; lreg="$2"; shift 2 ;;
      --right-region) require_value "$1" "${2-}"; rreg="$2"; shift 2 ;;
      --show-secrets) show=true; shift ;;
      *) usage_error "unknown option for diff: $1" ;;
    esac
  done
  [[ -n "${left}" && -n "${right}" ]] || usage_error "diff needs --left and --right"
  left=$(normalize_path "${left}")
  right=$(normalize_path "${right}")
  require_cmd jq
  make_tmpdir tmp
  fetch_side "${left}" "${lprof}" "${lreg}" "${tmp}/left.json"
  fetch_side "${right}" "${rprof}" "${rreg}" "${tmp}/right.json"

  if [[ "${show}" == true ]]; then
    log_warn "--show-secrets: SecureString values will be printed"
  fi

  # One line per name that is not identical. SecureString values are masked unless --show-secrets.
  jq -r -n --argjson show "${show}" --slurpfile l "${tmp}/left.json" --slurpfile r "${tmp}/right.json" '
    def m: map({key: .name, value: .}) | from_entries;
    def shown($p): if $p.type == "SecureString" and ($show | not) then "<hidden>" else ($p.value | tojson) end;
    ($l[0] | m) as $L | ($r[0] | m) as $R
    | ([$L, $R | keys[]] | unique)[] as $k
    | $L[$k] as $a | $R[$k] as $b
    | if $b == null then "ONLY_LEFT   \($k) (\($a.type))"
      elif $a == null then "ONLY_RIGHT  \($k) (\($b.type))"
      elif $a.type != $b.type then "TYPE        \($k): \($a.type) -> \($b.type)"
      elif $a.value != $b.value then
        "CHANGED     \($k) (\($a.type)): " +
        (if $a.type == "SecureString" and ($show | not) then "values differ (use --show-secrets to see them)"
         else "\(shown($a)) -> \(shown($b))" end)
      else empty end' >"${tmp}/diff.txt"

  local same
  same=$(jq -n --slurpfile l "${tmp}/left.json" --slurpfile r "${tmp}/right.json" '
    ($r[0] | map({key: .name, value: .}) | from_entries) as $R
    | [$l[0][] | select($R[.name] == {name, type, value})] | length')

  printf 'Diff: left=%s  right=%s\n' "${left}" "${right}"
  cat "${tmp}/diff.txt"
  local differences
  differences=$(wc -l <"${tmp}/diff.txt" | tr -d ' ')
  printf 'Summary: %s difference(s), %s identical\n' "${differences}" "${same}"
  ((differences == 0)) || exit "${EXIT_DIFFERENT}"
}

main() {
  local cmd="${1:-}"
  [[ -n "${cmd}" ]] || { usage >&2; exit "${EXIT_USAGE}"; }
  shift

  # Global options may appear anywhere after the command.
  local -a rest=()
  while (($# > 0)); do
    case "$1" in
      -h | --help) usage; exit 0 ;;
      --log-level) require_value "$1" "${2-}"; LOG_LEVEL="$2"; shift 2 ;;
      *) rest+=("$1"); shift ;;
    esac
  done

  case "${cmd}" in
    export) cmd_export ${rest[@]+"${rest[@]}"} ;;
    import) cmd_import ${rest[@]+"${rest[@]}"} ;;
    diff) cmd_diff ${rest[@]+"${rest[@]}"} ;;
    -h | --help | help) usage ;;
    *) usage_error "unknown command: ${cmd}" ;;
  esac
}

main "$@"
