#!/usr/bin/env bash
# backup-report.sh - Recovery Services Vault backup jobs of the last N hours, per protected item.
#
# For cron or a monitoring check: it prints a table and exits 5 when any job in the
# window failed, so the caller can alert. Read-only; it never changes the vault.
#
# Status per protected item (worst first):
#   FAILED        the latest job failed
#   RECOVERED     a job failed in the window, but a later one succeeded
#   LONG_RUNNING  the latest job is still running after --max-running
#   NO_JOB        protected, but no job at all in the window (missed schedule?)
#   WARNING       a job completed with warnings or was cancelled
#   IN_PROGRESS   the latest job is running
#   OK            every job in the window completed
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} -g RESOURCE_GROUP -v VAULT [options]

Report Azure Backup jobs of the last N hours for one Recovery Services Vault.

Options:
  -g, --resource-group RG   Resource group of the vault (required)
  -v, --vault-name NAME     Recovery Services Vault name (required)
  --hours N                 Look back N hours (default: 24)
  --max-running DUR         A job running longer than this is LONG_RUNNING (default: 8h)
  --fail-on-warnings        Also exit 5 for LONG_RUNNING, NO_JOB and WARNING items
  --json                    Machine-readable output
  --log-level LEVEL         debug|info|warn|error (default: info)
  -h, --help                Show this help

Needs: az (logged in; Backup Reader on the vault is enough), jq.
Exit codes: 0 no failed jobs, 1 error, 2 usage, 3 missing tool,
            5 at least one job failed (or a warning, with --fail-on-warnings).
EOF
}

RG=""
VAULT=""
HOURS=24
MAX_RUNNING=$((8 * 3600))
FAIL_ON_WARNINGS=false
JSON=false

parse_args() {
  while (($# > 0)); do
    case "$1" in
      -g | --resource-group) require_value "$1" "${2-}"; RG="$2"; shift 2 ;;
      -v | --vault-name) require_value "$1" "${2-}"; VAULT="$2"; shift 2 ;;
      --hours) require_value "$1" "${2-}"; require_int "$1" "$2"; HOURS="$2"; shift 2 ;;
      --max-running) require_value "$1" "${2-}"; MAX_RUNNING=$(require_duration "$1" "$2"); shift 2 ;;
      --fail-on-warnings) FAIL_ON_WARNINGS=true; shift ;;
      --json) JSON=true; shift ;;
      --log-level) require_value "$1" "${2-}"; LOG_LEVEL="$2"; shift 2 ;;
      -h | --help) usage; exit 0 ;;
      *) usage_error "unknown option: $1" ;;
    esac
  done
  [[ -n "${RG}" ]] || usage_error "--resource-group is required"
  [[ -n "${VAULT}" ]] || usage_error "--vault-name is required"
  ((HOURS >= 1)) || usage_error "--hours must be at least 1"
}

main() {
  parse_args "$@"
  check_az_access

  local now since tmp report
  make_tmpdir tmp
  now=$(now_epoch)
  since=$((now - HOURS * 3600))

  # 'az backup job list' takes UTC dates as d-m-Y and turns them into midnight, so an end
  # date of "today" would miss today's jobs. Ask for whole days up to tomorrow and filter
  # to the exact window below. (Recent CLIs also accept d-m-Y-H:M:S; d-m-Y works everywhere.)
  log_info "reading backup jobs and protected items of ${RG}/${VAULT}"
  # Files, not --argjson: a busy vault returns more JSON than one command-line argument may hold.
  az_cli backup job list --resource-group "${RG}" --vault-name "${VAULT}" \
    --start-date "$(date -u -d "@${since}" +%d-%m-%Y)" --end-date "$(date -u -d "@$((now + 86400))" +%d-%m-%Y)" \
    >"${tmp}/jobs.json" || die "cannot list backup jobs of ${RG}/${VAULT}"
  az_cli backup item list --resource-group "${RG}" --vault-name "${VAULT}" >"${tmp}/items.json" ||
    die "cannot list protected items of ${RG}/${VAULT}"

  report=$(jq -n --slurpfile jobs "${tmp}/jobs.json" --slurpfile items "${tmp}/items.json" --argjson now "${now}" \
    --argjson since "${since}" --argjson maxrun "${MAX_RUNNING}" "${JQ_DEFS}"'
    def rank: {FAILED: 0, RECOVERED: 1, LONG_RUNNING: 2, NO_JOB: 3, WARNING: 4, IN_PROGRESS: 5, OK: 6}[.];
    ([ $jobs[0][] | .properties | {
        item: .entityFriendlyName, type: (.backupManagementType // "-"), operation, status,
        start: (.startTime | epoch), end: (.endTime | epoch),
        errors: [.errorDetails[]? | {code: .errorCode, message: ((.errorString // "") | gsub("\\s+"; " "))}] }
      | select(.start != null and .start >= $since) ]) as $win
    | ([ $items[0][] | .properties | {item: .friendlyName, type: (.workloadType // "-"),
         protectionState: (.protectionState // "-")} ]) as $prot
    | ([$prot[].item, $win[].item] | unique) as $names
    | [ $names[] as $n
        | ($win | map(select(.item == $n)) | sort_by(.start)) as $j
        | ($prot | map(select(.item == $n)) | .[0]) as $p
        | ($j | last) as $last
        | {item: $n, type: ($p.type // $j[0].type // "-"), protectionState: ($p.protectionState // "-"),
           ok: ($j | map(select(.status == "Completed")) | length),
           warnings: ($j | map(select(.status == "CompletedWithWarnings" or .status == "Cancelled")) | length),
           failed: ($j | map(select(.status == "Failed")) | length),
           running: ($j | map(select(.status == "InProgress")) | length),
           lastOperation: ($last.operation // "-"), lastStatus: ($last.status // "-"), lastStart: ($last.start // null),
           errors: ([$j[] | select(.status == "Failed") | .errors[].code] | unique)}
        | .status = (
            if $last == null then (if .protectionState == "ProtectionStopped" then "STOPPED" else "NO_JOB" end)
            elif $last.status == "Failed" then "FAILED"
            elif .failed > 0 then "RECOVERED"
            elif $last.status == "InProgress" and ($now - $last.start) > $maxrun then "LONG_RUNNING"
            elif .warnings > 0 then "WARNING"
            elif $last.status == "InProgress" then "IN_PROGRESS"
            else "OK" end)
        | select(.status != "STOPPED") ]
    | sort_by((.status | rank), .item) as $rows
    | {since: ($since | todate), until: ($now | todate), items: $rows,
       failedJobs: [$win[] | select(.status == "Failed")] | sort_by(.start),
       counts: ($rows | group_by(.status | rank) | map({(.[0].status): length}) | add // {})}') ||
    die "unexpected output from az backup (could not build the report)"

  local failures warnings
  failures=$(jq '[.items[] | select(.status == "FAILED" or .status == "RECOVERED")] | length' <<<"${report}")
  warnings=$(jq '[.items[] | select(.status == "LONG_RUNNING" or .status == "NO_JOB" or .status == "WARNING")] | length' <<<"${report}")

  if [[ "${JSON}" == true ]]; then
    jq --arg vault "${VAULT}" --arg rg "${RG}" '{vault: $vault, resourceGroup: $rg} + .' <<<"${report}"
  else
    printf 'Backup jobs in vault %s (%s), last %sh (since %s)\n\n' "${VAULT}" "${RG}" "${HOURS}" "$(jq -r .since <<<"${report}")"
    if [[ "$(jq '.items | length' <<<"${report}")" -gt 0 ]]; then
      {
        printf 'STATUS\tITEM\tTYPE\tLAST_OPERATION\tLAST_STATUS\tLAST_START (UTC)\tOK\tWARN\tFAILED\tRUNNING\tERRORS\n'
        jq -r "${JQ_DEFS}"'.items[] | [.status, .item, .type, .lastOperation, .lastStatus, (.lastStart | utc),
          .ok, .warnings, .failed, .running, (if (.errors | length) == 0 then "-" else (.errors | join(",")) end)] | @tsv' <<<"${report}"
      } | print_table
    else
      echo "No protected items and no jobs in the window."
    fi
    if ((failures > 0)); then
      printf '\nFailed jobs:\n'
      jq -r "${JQ_DEFS}"'.failedJobs[] | "  \(.item)  \(.operation)  \(.start | utc)  " +
        (if (.errors | length) == 0 then "no error details" else (.errors | map("\(.code): \(.message)") | join(" | ")) end)' <<<"${report}"
    fi
    printf '\nSummary: %s item(s): %s\n' "$(jq '.items | length' <<<"${report}")" \
      "$(jq -r '.counts | to_entries | map("\(.value) \(.key)") | join(", ") | if . == "" then "none" else . end' <<<"${report}")"
  fi

  if ((failures > 0)); then
    log_error "${failures} protected item(s) had failed backup jobs in the last ${HOURS}h"
    return "${EXIT_FINDINGS}"
  fi
  if ((warnings > 0)); then
    log_warn "${warnings} protected item(s) need a look (LONG_RUNNING, NO_JOB or WARNING)"
    [[ "${FAIL_ON_WARNINGS}" != true ]] || return "${EXIT_FINDINGS}"
  fi
  return 0
}

main "$@"
