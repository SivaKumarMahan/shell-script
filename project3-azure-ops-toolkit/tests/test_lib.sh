#!/usr/bin/env bash
# Unit tests for lib.sh. Run with tests/run-tests.sh.

lib_sh() {
  # Run a snippet with lib.sh loaded, in a fresh bash.
  bash -c "source '${TOOLKIT_DIR}/lib.sh'; $1"
}

test_lib_parse_duration() {
  run lib_sh 'parse_duration 45; parse_duration 90m; parse_duration 2h; parse_duration 1d'
  assert_status 0
  assert_eq "${OUT}" $'45\n5400\n7200\n86400'
  run lib_sh 'parse_duration 5w'
  assert_status 1
  run lib_sh 'require_duration --timeout 5w'
  assert_status 2
  assert_contains "${ERR}" "needs a duration"
}

test_lib_epoch_handles_azure_timestamps() {
  # Azure returns 7 fraction digits and +00:00; also check other offsets and plain numbers.
  # shellcheck disable=SC2016  # ${JQ_DEFS} must expand in the child bash, not here
  run lib_sh 'printf "%s\n" "\"2026-09-30T12:00:00.1234567+00:00\"" "\"2026-09-30T14:00:00+02:00\"" "\"2026-09-30T12:00:00Z\"" "\"2026-09-30T07:00:00-05:00\"" 1790769600.75 |
      jq -r "${JQ_DEFS} epoch"'
  assert_status 0
  assert_eq "${OUT}" $'1790769600\n1790769600\n1790769600\n1790769600\n1790769600'
}

test_lib_require_value_rejects_missing_values() {
  run lib_sh 'require_value --vault ""'
  assert_status 2
  assert_contains "${ERR}" "option --vault needs a value"
  run lib_sh 'require_value --vault --other'
  assert_status 2
}

test_lib_confirm_refuses_without_terminal() {
  run lib_sh 'confirm "Delete everything?"'
  assert_status 4
  assert_contains "${ERR}" "--yes"
  run lib_sh 'ASSUME_YES=true; confirm "Delete everything?" && echo yes'
  assert_status 0
  assert_eq "${OUT}" "yes"
}

test_lib_az_wrapper_forces_json_and_logs_subscription() {
  run lib_sh 'check_az_access'
  assert_status 0
  assert_contains "${ERR}" "Azure subscription: sub-platform-test (00000000-0000-0000-0000-000000000000) as ops@example.com"
  assert_eq "$(cat "${MOCK_STATE}/calls.log")" "account show --output json --only-show-errors"
}

test_lib_az_access_failure_is_clear() {
  export AZ_BIN="${T}/no-login-az"
  printf '#!/bin/sh\necho "Please run az login to setup account." >&2\nexit 1\n' >"${AZ_BIN}"
  chmod +x "${AZ_BIN}"
  run lib_sh 'check_az_access'
  assert_status 1
  assert_contains "${ERR}" "run 'az login'"
  export AZ_BIN=/nonexistent/az
  run lib_sh 'check_az_access'
  assert_status 3
}

test_lib_logs_go_to_stderr_and_log_file() {
  run lib_sh "LOG_FILE='${T}/ops.log'; log_info hello; log_debug hidden"
  assert_status 0
  assert_eq "${OUT}" ""
  assert_contains "${ERR}" "[INFO]"
  assert_not_contains "${ERR}" "hidden"
  assert_contains "$(cat "${T}/ops.log")" "hello"
}
