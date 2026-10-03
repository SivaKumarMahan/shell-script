#!/usr/bin/env bash
# keyvault-secrets.sh - inspect Key Vault secrets without leaking them.
#
#   list      secret names and metadata (enabled, expiry, content type, updated)
#   export    the same metadata as a JSON file
#   diff      compare two vaults (dev vs prod) by name, metadata and optionally value
#   expiring  secrets that expire within N days (exit 5, for alerting)
#
# Secret VALUES are never printed, logged or written unless you pass --show-values.
# 'diff --compare-values' compares SHA-256 hashes in memory and only says "value differs";
# it never prints the hashes either (a hash of a short password can be brute-forced).
# This script only reads; it never changes a vault.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<EOF
Usage:
  ${SCRIPT_NAME} list     --vault NAME [--json] [--show-values]
  ${SCRIPT_NAME} export   --vault NAME --file PATH [--force] [--show-values]
  ${SCRIPT_NAME} diff     --left VAULT --right VAULT [--compare-values] [--show-values]
  ${SCRIPT_NAME} expiring --vault NAME [--days N] [--include-no-expiry] [--json]

Options:
  --vault NAME          Key Vault name
  --left / --right NAME Vaults to compare (for example kv-app-dev and kv-app-prod)
  --file PATH           Export file (created with mode 600; refuses to overwrite without --force)
  --compare-values      diff: also compare values (by hash, needs 'get' permission on secrets)
  --show-values         Print or export secret values. Use with care: they end up on screen or on disk.
  --days N              expiring: report secrets that expire within N days (default: 30)
  --include-no-expiry   expiring: also report enabled secrets without an expiry date
  --json                Machine-readable output
  --log-level LEVEL     debug|info|warn|error (default: info)
  -h, --help            Show this help

Permissions: 'list' on secrets for metadata; 'get' as well for --compare-values/--show-values
(RBAC: Key Vault Secrets User; metadata only: Key Vault Reader).
Exit codes: 0 ok, 1 error, 2 usage, 3 missing tool,
            5 diff found differences / expiring found secrets to act on.
EOF
}

CMD=""
VAULT=""
LEFT=""
RIGHT=""
FILE=""
FORCE=false
COMPARE_VALUES=false
SHOW_VALUES=false
DAYS=30
INCLUDE_NO_EXPIRY=false
JSON=false

parse_args() {
  (($# > 0)) || usage_error "a command is required: list, export, diff or expiring"
  case "$1" in
    list | export | diff | expiring) CMD="$1"; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage_error "unknown command: $1" ;;
  esac
  while (($# > 0)); do
    case "$1" in
      --vault) require_value "$1" "${2-}"; VAULT="$2"; shift 2 ;;
      --left) require_value "$1" "${2-}"; LEFT="$2"; shift 2 ;;
      --right) require_value "$1" "${2-}"; RIGHT="$2"; shift 2 ;;
      --file) require_value "$1" "${2-}"; FILE="$2"; shift 2 ;;
      --force) FORCE=true; shift ;;
      --compare-values) COMPARE_VALUES=true; shift ;;
      --show-values) SHOW_VALUES=true; shift ;;
      --days) require_value "$1" "${2-}"; require_int "$1" "$2"; DAYS="$2"; shift 2 ;;
      --include-no-expiry) INCLUDE_NO_EXPIRY=true; shift ;;
      --json) JSON=true; shift ;;
      --log-level) require_value "$1" "${2-}"; LOG_LEVEL="$2"; shift 2 ;;
      -h | --help) usage; exit 0 ;;
      *) usage_error "unknown option for ${CMD}: $1" ;;
    esac
  done
  case "${CMD}" in
    diff)
      [[ -n "${LEFT}" && -n "${RIGHT}" ]] || usage_error "diff needs --left and --right"
      if [[ "${SHOW_VALUES}" == true ]]; then COMPARE_VALUES=true; fi
      ;;
    export)
      [[ -n "${VAULT}" ]] || usage_error "export needs --vault"
      [[ -n "${FILE}" ]] || usage_error "export needs --file"
      ;;
    *) [[ -n "${VAULT}" ]] || usage_error "${CMD} needs --vault" ;;
  esac
}

# fetch_meta VAULT OUT: normalized metadata, sorted by name. No values.
fetch_meta() {
  local vault="$1" out="$2"
  log_info "reading secret metadata from ${vault}"
  az_cli keyvault secret list --vault-name "${vault}" | jq "${JQ_DEFS}"'
    [ .[] | {
        name,
        enabled: (.attributes.enabled != false),  # not "// true": jq treats false as missing
        expires: (.attributes.expires // null), expiresEpoch: (.attributes.expires | epoch),
        notBefore: (.attributes.notBefore // null),
        created: (.attributes.created // null), updated: (.attributes.updated // null),
        contentType: (.contentType // ""), tags: (.tags // {}), managed: (.managed // false) } ]
    | sort_by(.name)' >"${out}" || die "cannot list secrets in ${vault} (does it exist, and do you have 'list' permission?)"
  log_info "${vault}: $(jq length "${out}") secret(s)"
}

# fetch_values VAULT META OUT MODE: OUT = {name: value} (MODE=value) or {name: sha256} (MODE=hash)
# for enabled secrets. Values only travel through pipes and files in the private temp dir,
# never through command-line arguments, so they do not show up in 'ps'.
fetch_values() {
  local vault="$1" meta="$2" out="$3" mode="$4" name part n=0
  part="${out}.parts"
  : >"${part}"
  while IFS= read -r name; do
    if [[ "${mode}" == hash ]]; then
      local h
      h=$(az_cli keyvault secret show --vault-name "${vault}" --name "${name}" | jq -j '.value // ""' | sha256sum) ||
        die "cannot read secret '${name}' in ${vault} (needs 'get' permission)"
      jq -cn --arg n "${name}" --arg h "${h%% *}" '{($n): $h}' >>"${part}"
    else
      az_cli keyvault secret show --vault-name "${vault}" --name "${name}" | jq -c '{(.name): .value}' >>"${part}" ||
        die "cannot read secret '${name}' in ${vault} (needs 'get' permission)"
    fi
    n=$((n + 1))
  done < <(jq -r '.[] | select(.enabled) | .name' "${meta}")
  jq -s 'add // {}' "${part}" >"${out}"
  rm -f -- "${part}"
  log_info "${vault}: read ${n} value(s) ($([[ "${mode}" == hash ]] && echo "hashed in memory, not shown" || echo "will be shown"))"
}

# with_values META VALUES -> metadata with a .value field (disabled secrets get null).
with_values() {
  jq --slurpfile v "$2" 'map(. + {value: ($v[0][.name] // null)})' "$1"
}

cmd_list() {
  local tmp="$1" meta="$1/meta.json" data
  fetch_meta "${VAULT}" "${meta}"
  data="${meta}"
  if [[ "${SHOW_VALUES}" == true ]]; then
    log_warn "--show-values: secret values will be printed"
    fetch_values "${VAULT}" "${meta}" "${tmp}/values.json" value
    with_values "${meta}" "${tmp}/values.json" >"${tmp}/data.json"
    data="${tmp}/data.json"
  fi
  if [[ "${JSON}" == true ]]; then
    jq . "${data}"
    return 0
  fi
  {
    printf 'NAME\tENABLED\tEXPIRES (UTC)\tDAYS_LEFT\tCONTENT_TYPE\tUPDATED (UTC)%s\n' "$([[ "${SHOW_VALUES}" == true ]] && printf '\tVALUE')"
    jq -r --argjson now "$(now_epoch)" "${JQ_DEFS}"'.[] | [ .name, .enabled,
        (.expiresEpoch | utc), (if .expiresEpoch == null then "-" else ((.expiresEpoch - $now) / 86400 | floor) end),
        (if .contentType == "" then "-" else .contentType end), (.updated | epoch | utc) ]
      + (if has("value") then [(.value // "<disabled>")] else [] end) | @tsv' "${data}"
  } | print_table
}

cmd_export() {
  local tmp="$1" meta="$1/meta.json" data
  if [[ -e "${FILE}" && "${FORCE}" != true ]]; then
    die "${FILE} already exists; use --force to overwrite it"
  fi
  fetch_meta "${VAULT}" "${meta}"
  data="${meta}"
  if [[ "${SHOW_VALUES}" == true ]]; then
    log_warn "--show-values: the export file will contain secret values. Keep it private and delete it after use."
    fetch_values "${VAULT}" "${meta}" "${tmp}/values.json" value
    with_values "${meta}" "${tmp}/values.json" >"${tmp}/data.json"
    data="${tmp}/data.json"
  fi
  # Write to a private temp file first, then move it into place with mode 600.
  (umask 077 && jq --arg vault "${VAULT}" --arg at "$(date -u -d "@$(now_epoch)" +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson values "${SHOW_VALUES}" '{vault: $vault, exportedAt: $at, includesValues: $values, secrets: .}' \
    "${data}" >"${tmp}/export.json")
  mv -f -- "${tmp}/export.json" "${FILE}"
  chmod 600 "${FILE}"
  log_info "exported $(jq length "${meta}") secret(s) from ${VAULT} to ${FILE}$([[ "${SHOW_VALUES}" == true ]] && echo " (WITH values)" || echo " (metadata only)")"
}

cmd_diff() {
  local tmp="$1" l="$1/left.json" r="$1/right.json" result
  fetch_meta "${LEFT}" "${l}"
  fetch_meta "${RIGHT}" "${r}"
  echo '{}' >"${tmp}/lv.json"
  echo '{}' >"${tmp}/rv.json"
  if [[ "${COMPARE_VALUES}" == true ]]; then
    local mode=hash
    if [[ "${SHOW_VALUES}" == true ]]; then
      mode=value
      log_warn "--show-values: values that differ will be printed"
    fi
    fetch_values "${LEFT}" "${l}" "${tmp}/lv.json" "${mode}"
    fetch_values "${RIGHT}" "${r}" "${tmp}/rv.json" "${mode}"
  fi

  result=$(jq -n --slurpfile l "${l}" --slurpfile r "${r}" --slurpfile lv "${tmp}/lv.json" \
    --slurpfile rv "${tmp}/rv.json" --argjson cmp "${COMPARE_VALUES}" --argjson show "${SHOW_VALUES}" '
    ($l[0] | map({(.name): .}) | add // {}) as $L
    | ($r[0] | map({(.name): .}) | add // {}) as $R
    | ([$L, $R | keys[]] | unique) as $names
    | [ $names[] as $n
        | if ($R | has($n) | not) then {kind: "ONLY_LEFT", name: $n, why: []}
          elif ($L | has($n) | not) then {kind: "ONLY_RIGHT", name: $n, why: []}
          else {kind: "CHANGED", name: $n, why: (
              (if $L[$n].enabled != $R[$n].enabled then ["enabled \($L[$n].enabled) -> \($R[$n].enabled)"] else [] end)
            + (if $L[$n].contentType != $R[$n].contentType
               then ["contentType \($L[$n].contentType | tojson) -> \($R[$n].contentType | tojson)"] else [] end)
            + (if $cmp | not then []
               elif ($L[$n].enabled and $R[$n].enabled | not) then ["value not compared (disabled)"]
               elif $lv[0][$n] == $rv[0][$n] then []
               elif $show then ["value \($lv[0][$n] | tojson) -> \($rv[0][$n] | tojson)"]
               else ["value differs"] end))}
          end ]
    | {diffs: map(select(.kind != "CHANGED" or (.why | map(select(. != "value not compared (disabled)")) | length > 0))),
       same: map(select(.kind == "CHANGED" and (.why | map(select(. != "value not compared (disabled)")) | length == 0))) | length}')

  printf 'Diff: left=%s  right=%s%s\n' "${LEFT}" "${RIGHT}" \
    "$([[ "${COMPARE_VALUES}" == true ]] && echo "  (names, metadata and values)" || echo "  (names and metadata; add --compare-values for values)")"
  jq -r '.diffs[] | "\(.kind | . + " " * (11 - length)) \(.name)\(if (.why | length) > 0 then ": " + (.why | join("; ")) else "" end)"' <<<"${result}"
  local n
  n=$(jq '.diffs | length' <<<"${result}")
  printf 'Summary: %s difference(s), %s identical\n' "${n}" "$(jq .same <<<"${result}")"
  ((n == 0)) || return "${EXIT_FINDINGS}"
}

cmd_expiring() {
  local tmp="$1" meta="$1/meta.json" rows now
  now=$(now_epoch)
  fetch_meta "${VAULT}" "${meta}"
  rows=$(jq --argjson now "${now}" --argjson days "${DAYS}" --argjson noexp "${INCLUDE_NO_EXPIRY}" '
    [ .[] | select(.enabled)
      | if .expiresEpoch == null then (if $noexp then . + {status: "NO_EXPIRY", daysLeft: null} else empty end)
        elif .expiresEpoch <= $now then . + {status: "EXPIRED", daysLeft: ((.expiresEpoch - $now) / 86400 | floor)}
        elif .expiresEpoch <= $now + $days * 86400 then . + {status: "EXPIRING", daysLeft: ((.expiresEpoch - $now) / 86400 | floor)}
        else empty end ]
    | sort_by(.expiresEpoch // 1e12)' "${meta}")
  local disabled
  disabled=$(jq 'map(select(.enabled | not)) | length' "${meta}")
  ((disabled == 0)) || log_info "${disabled} disabled secret(s) ignored"

  if [[ "${JSON}" == true ]]; then
    jq '[.[] | {name, status, expires, daysLeft, contentType}]' <<<"${rows}"
  else
    printf 'Secrets in %s that are expired or expire within %s day(s)%s\n' "${VAULT}" "${DAYS}" \
      "$([[ "${INCLUDE_NO_EXPIRY}" == true ]] && echo ", plus secrets without an expiry date")"
    if [[ "$(jq length <<<"${rows}")" -gt 0 ]]; then
      {
        printf 'STATUS\tNAME\tEXPIRES (UTC)\tDAYS_LEFT\tCONTENT_TYPE\n'
        jq -r "${JQ_DEFS}"'.[] | [.status, .name, (.expiresEpoch | utc), (.daysLeft // "-"),
          (if .contentType == "" then "-" else .contentType end)] | @tsv' <<<"${rows}"
      } | print_table
    fi
    printf 'Summary: %s expired, %s expiring, %s without expiry\n' \
      "$(jq 'map(select(.status == "EXPIRED")) | length' <<<"${rows}")" \
      "$(jq 'map(select(.status == "EXPIRING")) | length' <<<"${rows}")" \
      "$(jq 'map(select(.status == "NO_EXPIRY")) | length' <<<"${rows}")"
  fi
  [[ "$(jq length <<<"${rows}")" -eq 0 ]] || return "${EXIT_FINDINGS}"
}

main() {
  parse_args "$@"
  check_az_access
  local tmp
  make_tmpdir tmp
  # Not in an '||' list: that would switch off 'set -e' inside the command.
  # A return of 5 (findings) ends the script with exit code 5.
  "cmd_${CMD}" "${tmp}"
}

main "$@"
