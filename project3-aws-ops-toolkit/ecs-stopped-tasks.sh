#!/usr/bin/env bash
# ecs-stopped-tasks.sh - report recently stopped ECS tasks per service (read-only).
#
# Shows stoppedReason, stopCode and container exit codes, plus a per-service summary.
# ECS keeps STOPPED tasks for only a short time (about 1 hour), so run this soon after an
# incident, or ship ECS task state-change events to logs (EventBridge) for longer history.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} --cluster NAME [--service NAME]... [--since DURATION] [--json]

Report ECS tasks that stopped recently, grouped by service. Read-only.

Options:
  --cluster NAME       ECS cluster name or ARN (required)
  --service NAME       Only this service (repeatable). Default: all services in the cluster
  --since DURATION     Only tasks stopped in this window: 30m, 2h, 1d (default: 1h)
  --json               Print JSON instead of a table (for jq or other tools)
  --log-level LEVEL    debug|info|warn|error (default: info)
  -h, --help           Show this help

Environment: AWS_PROFILE, AWS_REGION, AWS_ENDPOINT_URL, LOG_LEVEL, LOG_FILE.
Exit codes: 0 ok, 1 error, 2 usage, 3 missing tool.
EOF
}

CLUSTER=""
SINCE="1h"
OUTPUT="table"
declare -a SERVICES=()

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --cluster) require_value "$1" "${2-}"; CLUSTER="$2"; shift 2 ;;
      --service) require_value "$1" "${2-}"; SERVICES+=("$2"); shift 2 ;;
      --since) require_value "$1" "${2-}"; SINCE="$2"; shift 2 ;;
      --json) OUTPUT="json"; shift ;;
      --log-level) require_value "$1" "${2-}"; LOG_LEVEL="$2"; shift 2 ;;
      -h | --help) usage; exit 0 ;;
      *) usage_error "unknown option: $1" ;;
    esac
  done
  [[ -n "${CLUSTER}" ]] || usage_error "--cluster is required"
  parse_duration "${SINCE}" >/dev/null || usage_error "--since must look like 30m, 2h or 1d, got '${SINCE}'"
}

main() {
  parse_args "$@"
  check_aws_access

  local tmp since_s cutoff svc
  make_tmpdir tmp
  since_s=$(parse_duration "${SINCE}")
  cutoff=$(($(now_epoch) - since_s))

  if ((${#SERVICES[@]} == 0)); then
    log_info "listing services in cluster ${CLUSTER}"
    aws_cli ecs list-services --cluster "${CLUSTER}" >"${tmp}/services.json"
    mapfile -t SERVICES < <(jq -r '.serviceArns[]? | split("/") | last' "${tmp}/services.json")
    ((${#SERVICES[@]} > 0)) || { log_info "no services in cluster ${CLUSTER}"; exit 0; }
  fi

  # Collect stopped task ARNs for every service (the CLI follows pagination).
  : >"${tmp}/arns.txt"
  for svc in "${SERVICES[@]}"; do
    aws_cli ecs list-tasks --cluster "${CLUSTER}" --service-name "${svc}" --desired-status STOPPED \
      | jq -r '.taskArns[]?' >>"${tmp}/arns.txt"
  done
  local total
  total=$(wc -l <"${tmp}/arns.txt" | tr -d ' ')
  log_info "found ${total} stopped task(s) in ${#SERVICES[@]} service(s); describing them"

  # describe-tasks accepts at most 100 tasks per call.
  local -a batch=()
  local arn n=0
  : >"${tmp}/tasks.jsonl"
  while IFS= read -r arn || [[ -n "${arn}" ]]; do
    [[ -n "${arn}" ]] || continue
    batch+=("${arn}")
    if ((${#batch[@]} == 100)); then
      aws_cli ecs describe-tasks --cluster "${CLUSTER}" --tasks "${batch[@]}" | jq -c '.tasks[]' >>"${tmp}/tasks.jsonl"
      n=$((n + 1)); batch=()
    fi
  done <"${tmp}/arns.txt"
  if ((${#batch[@]} > 0)); then
    aws_cli ecs describe-tasks --cluster "${CLUSTER}" --tasks "${batch[@]}" | jq -c '.tasks[]' >>"${tmp}/tasks.jsonl"
    n=$((n + 1))
  fi
  log_debug "describe-tasks calls: ${n}"

  # Normalize, filter by time window, newest first.
  jq -s --argjson cutoff "${cutoff}" "${JQ_DEFS}"'
    def hint:
      if . == null then null
      elif . == 0 then "ok"
      elif . == 137 then "SIGKILL: OOM or killed after stop timeout"
      elif . == 139 then "SIGSEGV"
      elif . == 143 then "SIGTERM: normal stop"
      elif . == 1 then "application error"
      else null end;
    map({
        service: ((.group // "") | if startswith("service:") then ltrimstr("service:") else . end),
        task: (.taskArn | split("/") | last),
        taskDefinition: ((.taskDefinitionArn // "") | split("/") | last),
        stoppedAt: (.stoppedAt | epoch),
        stopCode: (.stopCode // "-"),
        stoppedReason: (.stoppedReason // "-"),
        containers: [(.containers // [])[] | {name, exitCode, reason, hint: (.exitCode | hint)}]
      })
    | map(select(.stoppedAt != null and .stoppedAt >= $cutoff))
    | sort_by(-.stoppedAt)
    | map(.stoppedAt |= utc)' "${tmp}/tasks.jsonl" >"${tmp}/report.json"

  if [[ "${OUTPUT}" == json ]]; then
    cat "${tmp}/report.json"
    return 0
  fi

  local count
  count=$(jq length "${tmp}/report.json")
  if ((count == 0)); then
    printf 'No tasks stopped in the last %s in cluster %s.\n' "${SINCE}" "${CLUSTER}"
    return 0
  fi

  printf 'Stopped tasks in cluster %s, last %s (newest first)\n\n' "${CLUSTER}" "${SINCE}"
  {
    printf 'SERVICE\tTASK\tTASK_DEF\tSTOPPED_AT (UTC)\tSTOP_CODE\tEXIT_CODES\tSTOPPED_REASON\n'
    jq -r '.[] | [
        .service, .task[0:12], .taskDefinition, .stoppedAt, .stopCode,
        ([.containers[] | "\(.name)=\(.exitCode // "-")"] | join(",")),
        .stoppedReason
      ] | @tsv' "${tmp}/report.json"
  } | if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else cat; fi

  printf '\nContainer details (non-zero or missing exit codes):\n'
  jq -r '.[] | . as $t | .containers[]
    | select(.exitCode != 0)
    | "  \($t.service) \($t.task[0:12]) \(.name): exit=\(.exitCode // "none")"
      + (if .hint then " (\(.hint))" else "" end)
      + (if .reason then " reason=\"\(.reason)\"" else "" end)' "${tmp}/report.json"

  printf '\nSummary per service:\n'
  jq -r 'group_by(.service)[] | "  \(.[0].service): \(length) stopped (" +
      ([group_by(.stopCode)[] | "\(length)x \(.[0].stopCode)"] | join(", ")) + ")"' "${tmp}/report.json"
}

main "$@"
