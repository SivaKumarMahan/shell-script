#!/usr/bin/env bash
# shellcheck disable=SC2034  # constants here are used by the scripts that source this file
# Shared helpers for the Azure ops toolkit. Source it, do not run it:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# Provides: logging, argument helpers, confirmation, temp dirs and an 'az' wrapper.
#
# Environment:
#   LOG_LEVEL   debug|info|warn|error (default: info)
#   LOG_FILE    also append log lines to this file (optional)
#   AZ_BIN      Azure CLI binary to use (default: az; tests point it at a mock)
#
# The subscription is the one selected with 'az account set --subscription ...'.
# check_az_access logs it, so the operator always sees where a script is about to act.

# Guard against double sourcing.
[[ -n "${_OPS_LIB_LOADED:-}" ]] && return 0
_OPS_LIB_LOADED=1

if ((BASH_VERSINFO[0] < 4)); then
  echo "error: bash 4 or newer is required (macOS: brew install bash)" >&2
  exit 3
fi

# Exit codes shared by all scripts.
readonly EXIT_OK=0
readonly EXIT_FAILURE=1     # runtime error (az call failed, file problem, operation failed)
readonly EXIT_USAGE=2       # bad option or missing value
readonly EXIT_DEPENDENCY=3  # required tool missing
readonly EXIT_ABORTED=4     # user said no at the confirmation prompt (or no terminal)
readonly EXIT_FINDINGS=5    # report found something to act on (diff, expiring secrets, failed backups)
readonly EXIT_UNHEALTHY=6   # health gate failed (AKS upgrade stopped between steps)

SCRIPT_NAME="${SCRIPT_NAME:-${0##*/}}"
ASSUME_YES="${ASSUME_YES:-false}"

# Azure CLI defaults that make scripts predictable: no colors, no surveys.
export AZURE_CORE_NO_COLOR=true
export AZURE_CORE_SURVEY_MESSAGE=false

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

# require_value OPTION VALUE: fail if an option has no value ("--vault" at the end, or "--vault --x").
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

# require_duration OPTION VALUE: print seconds, or exit 2 with a clear message.
require_duration() {
  parse_duration "$2" || usage_error "option $1 needs a duration like 30s, 10m, 2h or 7d, got '$2'"
}

# require_regex OPTION VALUE: exit 2 unless VALUE is a valid jq (Oniguruma) regex.
require_regex() {
  jq -n --arg re "$2" '"x" | test($re)' >/dev/null 2>&1 || usage_error "option $1 is not a valid regex: $2"
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
# Without a terminal it refuses, so a cron job never changes things by accident.
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

# print_table: tab-separated rows on stdin -> aligned columns (falls back to plain TSV).
print_table() {
  if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else cat; fi
}

# jq helpers shared by the scripts. Use as: jq "${JQ_DEFS} <program>".
# epoch: Azure timestamps are ISO 8601 with up to 7 fraction digits and an offset
# ("2026-09-30T10:15:00.1234567+00:00") or "Z". jq 1.6 fromdateiso8601 only accepts
# "...Z" without a fraction, so we drop the fraction and apply the offset ourselves.
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

# ---------- Azure CLI wrapper ----------

# az_cli <group> <command> [args...]
# Forces JSON output and hides warnings (they would mix with data on stderr).
az_cli() {
  # Log only the command words, never the argument values (they can be names you consider sensitive).
  local -a words=()
  local a
  for a in "$@"; do
    [[ "${a}" == -* ]] && break
    words+=("${a}")
  done
  log_debug "az ${words[*]}"
  "${AZ_BIN:-az}" "$@" --output json --only-show-errors
}

# check_az_access: fail early with a clear message instead of on the first real call,
# and log which subscription and identity the script will act as.
check_az_access() {
  require_cmd "${AZ_BIN:-az}" jq
  local acct
  if ! acct=$(az_cli account show 2>&1); then
    die "cannot use the Azure CLI (run 'az login' and 'az account set --subscription ...'): ${acct}"
  fi
  log_info "Azure subscription: $(jq -r '"\(.name // "unknown") (\(.id // "?")) as \(.user.name // "unknown")"' <<<"${acct}")"
}
