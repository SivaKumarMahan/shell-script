#!/usr/bin/env bash
# ====================================================
# Linux System Information Tool
# Author: Prashanth Teja
# Description: Displays key system statistics in a clean, colorized format.
# ====================================================
# Linux only (reads /proc and /etc/os-release).
#
# Exit codes:
#   0  success
#   2  usage error
#   3  unsupported OS (no /proc)

set -euo pipefail

readonly SCRIPT_NAME="${0##*/}"

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [--no-color] [-h|--help]

Print a short summary of this Linux machine.

Options:
  --no-color   Do not use colors (also disabled when NO_COLOR is set
               or when output is not a terminal)
  -h, --help   Show this help and exit

Disk usage is shown in yellow at 75% or more and in red at 90% or more.
EOF
}

USE_COLOR=true
while (($# > 0)); do
  case "$1" in
    --no-color) USE_COLOR=false ;;
    -h | --help) usage; exit 0 ;;
    *) printf '%s: unknown option: %s\n' "${SCRIPT_NAME}" "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
if [[ -n "${NO_COLOR:-}" || ! -t 1 ]]; then
  USE_COLOR=false
fi

if [[ ! -r /proc/stat || ! -r /proc/meminfo ]]; then
  printf '%s: this script needs Linux /proc\n' "${SCRIPT_NAME}" >&2
  exit 3
fi

# Define color codes ($'...' gives real escape bytes, so plain printf works)
if [[ "${USE_COLOR}" == true ]]; then
  GREEN=$'\e[32m' CYAN=$'\e[36m' YELLOW=$'\e[33m' RED=$'\e[31m' RESET=$'\e[0m'
else
  GREEN='' CYAN='' YELLOW='' RED='' RESET=''
fi

# Get hostname ('hostname' is missing in some minimal containers)
# Note: we do not overwrite bash's own HOSTNAME variable.
host_name=$(hostname 2>/dev/null || uname -n)

# Get OS info (read in a subshell so the file cannot change our variables)
os_name=$(
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release && printf '%s' "${PRETTY_NAME:-${NAME:-unknown}}"
  else
    uname -sr
  fi
)

# Get uptime ('uptime -p' does not exist in BusyBox)
if ! up_time=$(uptime -p 2>/dev/null); then
  up_time=$(awk '{s=int($1); printf "up %d days, %d hours, %d minutes", s/86400, (s%86400)/3600, (s%3600)/60}' /proc/uptime)
fi

# Get CPU usage: busy % over 1 second from /proc/stat.
# Parsing 'top' column 8 breaks when a value reaches 100.0 or the layout differs.
read_cpu() { awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8+$9, $5+$6; exit}' /proc/stat; }
cpu_a=$(read_cpu)
sleep 1
cpu_b=$(read_cpu)
cpu_usage=$(awk -v a="${cpu_a}" -v b="${cpu_b}" 'BEGIN {
  split(a, x, " "); split(b, y, " "); dt = y[1] - x[1]; di = y[2] - x[2]
  if (dt <= 0) print "n/a"; else printf "%.1f%%", (dt - di) * 100 / dt }')

# Get total and used memory (used = MemTotal - MemAvailable, like 'free')
mem_usage=$(awk '
  function human(kb) { return kb >= 1048576 ? sprintf("%.1fGi", kb / 1048576) : sprintf("%.0fMi", kb / 1024) }
  /^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 }
  END { printf "%s / %s", human(t - a), human(t) }' /proc/meminfo)

# Get disk usage of / (-P keeps one line per filesystem even with long device names)
disk_pct=$(df -P / | awk 'NR==2 {gsub("%", "", $5); print $5}')
disk_human=$(df -P -h / | awk 'NR==2 {print $3 " / " $2}')
disk_color="${GREEN}"
if ((disk_pct >= 90)); then
  disk_color="${RED}"
elif ((disk_pct >= 75)); then
  disk_color="${YELLOW}"
fi

# Get IP address ('hostname -I' is Linux net-tools only; fall back to 'ip')
ip_addr=$(hostname -I 2>/dev/null | awk '{print $1}') || true
if [[ -z "${ip_addr}" ]] && command -v ip >/dev/null 2>&1; then
  ip_addr=$(ip -4 -o addr show scope global 2>/dev/null | awk '{split($4, a, "/"); print a[1]; exit}') || true
fi
ip_addr="${ip_addr:-unknown}"

# Get logged-in users (unique names; 'who' prints one line per session)
users=$( (who 2>/dev/null || true) | awk '{print $1}' | sort -u | awk 'END {print NR}')

printf '%s==============================\n' "${CYAN}"
printf '   LINUX SYSTEM INFORMATION\n'
printf '==============================%s\n' "${RESET}"
printf '%sHostname:%s %s\n' "${GREEN}" "${RESET}" "${host_name}"
printf '%sOperating System:%s %s\n' "${GREEN}" "${RESET}" "${os_name}"
printf '%sUptime:%s %s\n' "${GREEN}" "${RESET}" "${up_time}"
printf '%sCPU Usage:%s %s\n' "${GREEN}" "${RESET}" "${cpu_usage}"
printf '%sMemory Usage:%s %s\n' "${GREEN}" "${RESET}" "${mem_usage}"
printf '%sDisk Usage:%s %s%s%%%s (%s)\n' "${GREEN}" "${RESET}" "${disk_color}" "${disk_pct}" "${RESET}" "${disk_human}"
printf '%sIP Address:%s %s\n' "${GREEN}" "${RESET}" "${ip_addr}"
printf '%sLogged-in Users:%s %s\n' "${GREEN}" "${RESET}" "${users}"
printf '%s==============================%s\n' "${CYAN}" "${RESET}"
printf 'Last Checked: %s\n' "$(date)"
printf '%s==============================%s\n' "${CYAN}" "${RESET}"
