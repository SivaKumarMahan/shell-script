#!/usr/bin/env bash
# Assertions and environment setup for tests/run-tests.sh.
# shellcheck disable=SC2034  # OUT/ERR/STATUS are read by the test files

# 2026-09-30T12:00:00Z: the fixtures are written relative to this "now".
readonly FIXTURE_NOW=1790769600

setup_test_env() {
  T=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf -- '${T}'" EXIT
  export MOCK_STATE="${T}/state" MOCK_FIXTURES="${TESTS_DIR}/fixtures"
  mkdir -p "${MOCK_STATE}"
  : >"${MOCK_STATE}/calls.log"
  export AWS_BIN="${TESTS_DIR}/mocks/aws"
  export OPS_NOW="${FIXTURE_NOW}" AWS_REGION=eu-west-1 LOG_LEVEL=info TMPDIR="${T}"
  unset AWS_ENDPOINT_URL AWS_PROFILE LOG_FILE MOCK_FAIL_DIGEST
}

# run CMD...: run without stopping on failure; sets OUT (stdout), ERR (stderr), STATUS.
run() {
  set +e
  "$@" >"${T}/out" 2>"${T}/err" </dev/null
  STATUS=$?
  set -e
  OUT=$(cat "${T}/out")
  ERR=$(cat "${T}/err")
}

fail() {
  printf 'assertion failed: %s\n' "$*"
  printf -- '--- stdout ---\n%s\n--- stderr ---\n%s\n' "${OUT:-}" "${ERR:-}"
  exit 1
}

assert_status() { [[ "${STATUS}" == "$1" ]] || fail "expected exit $1, got ${STATUS}"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "expected to find '$2'"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "did not expect to find '$2'"; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected '$2', got '$1'"; }

# count_calls PATTERN: how many mock AWS calls matched PATTERN (grep -E)
count_calls() { grep -cE "$1" "${MOCK_STATE}/calls.log" || true; }
