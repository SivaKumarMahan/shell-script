#!/usr/bin/env bash
# shellcheck disable=SC2034  # constants here are used by the scripts that source this file
# Shared helpers for the AWS ops toolkit. Source it, do not run it:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# Provides: logging, argument helpers, confirmation, temp dirs and an 'aws' wrapper.
#
# Environment:
#   LOG_LEVEL         debug|info|warn|error (default: info)
#   LOG_FILE          also append log lines to this file (optional)
#   AWS_ENDPOINT_URL  send every AWS call to this endpoint (LocalStack: http://localhost:4566)
#   AWS_REGION        region (falls back to AWS_DEFAULT_REGION)
#   AWS_BIN           AWS CLI binary to use (default: aws; tests point it at a mock)

# Guard against double sourcing.
[[ -n "${_OPS_LIB_LOADED:-}" ]] && return 0
_OPS_LIB_LOADED=1

if ((BASH_VERSINFO[0] < 4)); then
  echo "error: bash 4 or newer is required (macOS: brew install bash)" >&2
  exit 3
fi

# Exit codes shared by all scripts.
readonly EXIT_OK=0
readonly EXIT_FAILURE=1     # runtime error (AWS call failed, file problem, ...)
readonly EXIT_USAGE=2       # bad option or missing value
readonly EXIT_DEPENDENCY=3  # required tool missing
readonly EXIT_ABORTED=4     # user said no at the confirmation prompt
readonly EXIT_DIFFERENT=5   # 'diff' found differences (like diff(1) returning 1)

SCRIPT_NAME="${SCRIPT_NAME:-${0##*/}}"
DRY_RUN="${DRY_RUN:-false}"
ASSUME_YES="${ASSUME_YES:-false}"

# AWS CLI defaults that make scripts predictable: no pager, sane retries.
export AWS_PAGER=""
export AWS_RETRY_MODE="${AWS_RETRY_MODE:-standard}"
export AWS_MAX_ATTEMPTS="${AWS_MAX_ATTEMPTS:-5}"

# ---------- logging (always to stderr, so stdout stays clean for data) ----------

_log_level_num() {
  case "$1" in
    debug) echo 10 ;; info) echo 20 ;; warn) echo 30 ;; error) echo 40 ;; *) echo 20 ;;
  esac
}

_log() {
  local level="$1"; shift
  local want have line
  want=$(_log_level_num "${LOG_LEVEL:-info}")
  have=$(_log_level_num "${level}")
  ((have >= want)) || return 0
  line="$(date -u +%Y-%m-%dT%H:%M:%SZ) [${level^^}] ${SCRIPT_NAME}: $*"
  printf '%s\n' "${line}" >&2
  if [[ -n "${LOG_FILE:-}" ]]; then
    printf '%s\n' "${line}" >>"${LOG_FILE}"
  fi
}

log_debug() { _log debug "$@"; }
log_info() { _log info "$@"; }
log_warn() { _log warn "$@"; }
log_error() { _log error "$@"; }

# die "message" [exit_code]
die() {
  log_error "$1"
  exit "${2:-${EXIT_FAILURE}}"
}

# usage_error "message": print the message and a hint, exit 2.
usage_error() {
  log_error "$1"
  printf "Run '%s --help' for usage.\n" "${SCRIPT_NAME}" >&2
  exit "${EXIT_USAGE}"
}

# ---------- argument helpers ----------

# require_value OPTION VALUE: fail if an option has no value ("--path" at the end, or "--path --x").
require_value() {
  local opt="$1" val="${2-}"
  if [[ -z "${val}" || "${val}" == --* ]]; then
    usage_error "option ${opt} needs a value"
  fi
}

# require_int OPTION VALUE: fail unless VALUE is a non-negative integer.
require_int() {
  [[ "$2" =~ ^[0-9]+$ ]] || usage_error "option $1 needs a whole number, got '$2'"
}

# parse_duration 90m -> 5400. Units: s, m, h, d. A bare number means seconds.
parse_duration() {
  local v="$1" n unit
  [[ "${v}" =~ ^([0-9]+)([smhd]?)$ ]] || return 1
  n="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]:-s}"
  case "${unit}" in
    s) echo "${n}" ;; m) echo $((n * 60)) ;; h) echo $((n * 3600)) ;; d) echo $((n * 86400)) ;;
  esac
}

# require_cmd cmd...: exit 3 if a tool is missing.
require_cmd() {
  local c
  for c in "$@"; do
    command -v "${c}" >/dev/null 2>&1 || die "required command not found: ${c}" "${EXIT_DEPENDENCY}"
  done
}

# ---------- safety helpers ----------

# confirm "question": returns 0 on yes. With --yes it does not ask.
# Without a terminal it refuses, so a cron job never deletes things by accident.
confirm() {
  local answer
  if [[ "${ASSUME_YES}" == true ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    die "no terminal to confirm '$1'; re-run with --yes to proceed non-interactively" "${EXIT_ABORTED}"
  fi
  read -r -p "$1 [y/N] " answer
  [[ "${answer}" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# make_tmpdir VAR: create a private temp dir, store its path in VAR, delete it on exit.
make_tmpdir() {
  local _ops_dir
  _ops_dir=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/${SCRIPT_NAME%.sh}.XXXXXX")
  # shellcheck disable=SC2064  # expand now: the trap must remove this exact path
  trap "rm -rf -- '${_ops_dir}'" EXIT
  printf -v "$1" '%s' "${_ops_dir}"
}

# now_epoch: current Unix time. OPS_NOW lets tests pin "now" so fixtures do not expire.
now_epoch() {
  if [[ -n "${OPS_NOW:-}" ]]; then echo "${OPS_NOW}"; else date +%s; fi
}

# jq helpers shared by the scripts. Use as: jq "${JQ_DEFS} <program>".
# epoch: AWS CLI timestamps are ISO 8601 with fraction and offset
# ("2026-09-30T10:15:00.123000+02:00") or plain numbers (cli_timestamp_format=none).
# jq 1.6 fromdateiso8601 only accepts "...Z", so we drop the fraction and apply the offset.
# shellcheck disable=SC2016  # $m etc. are jq variables, not shell
readonly JQ_DEFS='
def epoch:
  if type == "number" then floor
  elif type == "string" then
    capture("^(?<dt>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(?<tz>Z|[+-][0-9]{2}:?[0-9]{2})?$") as $m
    | ($m.dt + "Z" | fromdateiso8601)
      - (if ($m.tz // "Z") == "Z" then 0
         else ($m.tz | capture("(?<s>[+-])(?<h>[0-9]{2}):?(?<mi>[0-9]{2})")
               | (if .s == "-" then -1 else 1 end) * ((.h | tonumber) * 3600 + (.mi | tonumber) * 60))
         end)
  else null end;
def utc: if . == null then "-" else todate end;
'

# ---------- AWS wrapper ----------

# aws_cli <service> <operation> [args...]
# Adds --endpoint-url (LocalStack) and --region, forces JSON output.
# AWS CLI v2.13+ reads AWS_ENDPOINT_URL by itself; the explicit flag also covers older CLIs.
aws_cli() {
  local -a args=()
  local region="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
  if [[ -n "${AWS_ENDPOINT_URL:-}" ]]; then
    args+=(--endpoint-url "${AWS_ENDPOINT_URL}")
  fi
  if [[ -n "${region}" ]]; then
    args+=(--region "${region}")
  fi
  # Never log argument values: they may contain names you consider sensitive.
  log_debug "aws $1 $2 (endpoint=${AWS_ENDPOINT_URL:-default}, region=${region:-default}, profile=${AWS_PROFILE:-default})"
  "${AWS_BIN:-aws}" "${args[@]}" --output json "$@"
}

# check_aws_access: fail early with a clear message instead of on the first real call.
check_aws_access() {
  require_cmd "${AWS_BIN:-aws}" jq
  local who
  if ! who=$(aws_cli sts get-caller-identity 2>&1); then
    die "cannot call AWS (check credentials, AWS_PROFILE, AWS_REGION, AWS_ENDPOINT_URL): ${who}"
  fi
  log_info "AWS identity: $(jq -r '.Arn // "unknown"' <<<"${who}")${AWS_ENDPOINT_URL:+ via ${AWS_ENDPOINT_URL}}"
}
