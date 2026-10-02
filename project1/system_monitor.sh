#!/usr/bin/env bash
# ----------------------------------------
# Linux System Resource Monitoring Script
# ----------------------------------------
# Appends a report (CPU, memory, disk, top processes, uptime) to a log file.
# Linux only: it reads /proc and uses GNU df/ps options.
#
# Exit codes:
#   0  report written
#   1  runtime error (for example the log file is not writable)
#   2  usage error (bad option or value)
#   3  missing dependency or unsupported OS

set -euo pipefail

readonly SCRIPT_NAME="${0##*/}"

# Defaults. The environment can override the log path, flags override both.
LOG_FILE="${SYSTEM_MONITOR_LOG:-/var/log/system_monitor.log}"
TOP_N=5
ALSO_STDOUT=false

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [-l LOG_FILE] [-n NUM] [-s] [-h]

Append a system resource report to a log file.

Options:
  -l LOG_FILE  Log file to append to (default: ${LOG_FILE})
               Can also be set with SYSTEM_MONITOR_LOG.
  -n NUM       Number of top memory processes to show (default: ${TOP_N})
  -s           Also print the report to stdout
  -h           Show this help and exit

Exit codes: 0 ok, 1 runtime error, 2 usage error, 3 missing dependency.
EOF
}

err() { printf '%s: error: %s\n' "${SCRIPT_NAME}" "$*" >&2; }

parse_args() {
  local opt
  while getopts ':l:n:sh' opt; do
    case "${opt}" in
      l) LOG_FILE="${OPTARG}" ;;
      n) TOP_N="${OPTARG}" ;;
      s) ALSO_STDOUT=true ;;
      h) usage; exit 0 ;;
      :) err "option -${OPTARG} needs a value"; usage >&2; exit 2 ;;
      *) err "unknown option -${OPTARG}"; usage >&2; exit 2 ;;
    esac
  done
  shift $((OPTIND - 1))
  if (($# > 0)); then
    err "unexpected argument: $1"; usage >&2; exit 2
  fi
  if ! [[ "${TOP_N}" =~ ^[1-9][0-9]*$ ]]; then
    err "-n must be a positive integer, got '${TOP_N}'"; exit 2
  fi
}

check_deps() {
  local cmd
  if [[ ! -r /proc/stat || ! -r /proc/meminfo ]]; then
    err "this script needs Linux /proc (not available on this OS)"; exit 3
  fi
  for cmd in awk df ps sort date; do
    command -v "${cmd}" >/dev/null 2>&1 || { err "missing command: ${cmd}"; exit 3; }
  done
}

# CPU busy % measured over 1 second from /proc/stat.
# This avoids parsing 'top', whose column layout changes between versions and locales.
cpu_usage() {
  local a b
  a=$(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8+$9, $5+$6; exit}' /proc/stat)
  sleep 1
  b=$(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8+$9, $5+$6; exit}' /proc/stat)
  # Fields: total idle(idle+iowait)
  awk -v a="${a}" -v b="${b}" 'BEGIN {
    split(a, x, " "); split(b, y, " ")
    dt = y[1] - x[1]; di = y[2] - x[2]
    if (dt <= 0) { print "CPU Load: n/a"; exit }
    printf "CPU Load: %.1f%%\n", (dt - di) * 100 / dt
  }'
}

# Memory from /proc/meminfo in kB. "Used" = MemTotal - MemAvailable (same as modern 'free').
# Computing on raw numbers fixes the old bug of dividing 'free -h' strings like "800Mi" / "15Gi".
memory_usage() {
  awk '
    function human(kb) {
      if (kb >= 1048576) return sprintf("%.1fGi", kb / 1048576)
      return sprintf("%.0fMi", kb / 1024)
    }
    /^MemTotal:/     { total = $2 }
    /^MemAvailable:/ { avail = $2 }
    END {
      if (total == 0) { print "Memory: n/a"; exit }
      used = total - avail
      printf "Used: %s / Total: %s (%.2f%%)\n", human(used), human(total), used * 100 / total
    }' /proc/meminfo
}

# Total of real block-device filesystems ("/dev/..."), each device counted once.
# "% used" uses the same formula as df: used / (used + available), so reserved blocks are excluded.
# This replaces 'df --total', which is GNU-only and also counted tmpfs, snaps and bind mounts.
disk_usage() {
  local out
  # df can return non-zero if one mount is unreadable; we still use the lines it printed.
  out=$(df -P -k 2>/dev/null) || true
  awk '
    function human(kb) {
      if (kb >= 1073741824) return sprintf("%.1fT", kb / 1073741824)
      if (kb >= 1048576)    return sprintf("%.0fG", kb / 1048576)
      return sprintf("%.0fM", kb / 1024)
    }
    NR > 1 && $1 ~ /^\/dev\// && !seen[$1]++ { size += $2; used += $3; avail += $4 }
    END {
      if (size == 0) { print "Disk: n/a (no /dev filesystems found)"; exit }
      printf "Used: %s / %s (%d%% used)\n", human(used), human(size), (used * 100 + used + avail - 1) / (used + avail)
    }' <<<"${out}"
}

top_processes() {
  local out
  # awk/sort read all input, so ps never gets SIGPIPE (head -6 can cause exit 141 with pipefail).
  if out=$(ps -eo pid,comm,%mem,%cpu --sort=-%mem 2>/dev/null); then
    awk -v n="$((TOP_N + 1))" 'NR <= n' <<<"${out}"
  elif out=$(ps -o pid,rss,comm 2>/dev/null); then
    # BusyBox ps has no --sort or %mem: sort by resident memory (RSS, KiB) instead.
    awk 'NR == 1' <<<"${out}"
    awk 'NR > 1' <<<"${out}" | sort -k2,2 -h -r | awk -v n="${TOP_N}" 'NR <= n'
  else
    echo "n/a (ps failed)"
  fi
}

system_uptime() {
  if uptime -p >/dev/null 2>&1; then
    uptime -p
  else
    # Fallback for systems without 'uptime -p' (for example BusyBox).
    awk '{s=int($1); printf "up %d days, %d hours, %d minutes\n", s/86400, (s%86400)/3600, (s%3600)/60}' /proc/uptime
  fi
}

build_report() {
  local sep="----------------------------------------"
  printf '%s\n' "${sep}"
  printf 'System Resource Report - %s\n' "$(date +"%Y-%m-%d %H:%M:%S")"
  printf '%s\n' "${sep}"
  printf 'CPU Usage:\n%s\n\n' "$(cpu_usage)"
  printf 'Memory Usage:\n%s\n\n' "$(memory_usage)"
  printf 'Disk Usage:\n%s\n\n' "$(disk_usage)"
  printf 'Top %s Memory Consuming Processes:\n%s\n\n' "${TOP_N}" "$(top_processes)"
  printf 'System Uptime:\n%s\n' "$(system_uptime)"
  printf '%s\n' "${sep}"
}

main() {
  parse_args "$@"
  check_deps

  local log_dir report
  log_dir=$(dirname -- "${LOG_FILE}")
  if [[ ! -d "${log_dir}" ]]; then
    err "log directory does not exist: ${log_dir}"; exit 1
  fi
  if [[ -e "${LOG_FILE}" && ! -w "${LOG_FILE}" ]] || [[ ! -e "${LOG_FILE}" && ! -w "${log_dir}" ]]; then
    err "cannot write ${LOG_FILE} (run with sudo, or use -l to pick another file)"; exit 1
  fi

  report=$(build_report)
  printf '%s\n\n' "${report}" >>"${LOG_FILE}"
  if [[ "${ALSO_STDOUT}" == true ]]; then
    printf '%s\n' "${report}"
  fi
  echo "Report saved to ${LOG_FILE}" >&2
}

main "$@"
