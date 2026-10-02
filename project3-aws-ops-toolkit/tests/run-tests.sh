#!/usr/bin/env bash
# Tiny test runner: plain bash, no dependencies besides jq.
#
#   tests/run-tests.sh            run every test_* function in tests/test_*.sh
#   tests/run-tests.sh ecr        run only tests whose name contains "ecr"
#
# Each test runs in its own subshell with a fresh temp dir and the mock AWS CLI,
# so tests never call real AWS.
set -uo pipefail

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export TESTS_DIR
TOOLKIT_DIR=$(dirname "${TESTS_DIR}")
export TOOLKIT_DIR
FILTER="${1:-}"

pass=0
fail=0
declare -a failed=()

for file in "${TESTS_DIR}"/test_*.sh; do
  mapfile -t fns < <(grep -oE '^test_[A-Za-z0-9_]+\(\)' "${file}" | tr -d '()')
  for fn in "${fns[@]}"; do
    if [[ -n "${FILTER}" && "${fn}" != *"${FILTER}"* ]]; then continue; fi
    log=$(mktemp)
    (
      set -euo pipefail
      # shellcheck source=helpers.sh
      source "${TESTS_DIR}/helpers.sh"
      # shellcheck disable=SC1090
      source "${file}"
      setup_test_env
      "${fn}"
    ) >"${log}" 2>&1 </dev/null
    rc=$?
    if ((rc == 0)); then
      pass=$((pass + 1))
      printf 'ok    %s\n' "${fn}"
    else
      fail=$((fail + 1))
      failed+=("${fn}")
      printf 'FAIL  %s (rc=%s)\n' "${fn}" "${rc}"
      sed 's/^/      | /' "${log}"
    fi
    rm -f -- "${log}"
  done
done

printf '\n%s passed, %s failed\n' "${pass}" "${fail}"
if ((fail > 0)); then
  printf 'failed: %s\n' "${failed[*]}"
  exit 1
fi
