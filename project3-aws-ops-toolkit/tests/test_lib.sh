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
}

test_lib_epoch_handles_offsets_fractions_and_numbers() {
  # shellcheck disable=SC2016  # ${JQ_DEFS} must expand in the child bash, not here
  run lib_sh 'printf "%s\n" "\"2026-09-30T14:00:00.123000+02:00\"" "\"2026-09-30T12:00:00Z\"" "\"2026-09-30T07:00:00-05:00\"" 1790769600.75 |
      jq -r "${JQ_DEFS} epoch"'
  assert_status 0
  assert_eq "${OUT}" $'1790769600\n1790769600\n1790769600\n1790769600'
}

test_lib_require_value_rejects_missing_values() {
  run lib_sh 'require_value --path ""'
  assert_status 2
  assert_contains "${ERR}" "option --path needs a value"
  run lib_sh 'require_value --path --other'
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

test_lib_aws_wrapper_adds_endpoint_and_region() {
  run env AWS_ENDPOINT_URL=http://localhost:4566 bash -c "source '${TOOLKIT_DIR}/lib.sh'; aws_cli sts get-caller-identity"
  assert_status 0
  assert_contains "$(cat "${MOCK_STATE}/calls.log")" "--endpoint-url http://localhost:4566 --region eu-west-1 --output json sts get-caller-identity"
}

test_lib_logs_go_to_stderr_and_log_file() {
  run lib_sh "LOG_FILE='${T}/ops.log'; log_info hello; log_debug hidden"
  assert_status 0
  assert_eq "${OUT}" ""
  assert_contains "${ERR}" "[INFO]"
  assert_not_contains "${ERR}" "hidden"
  assert_contains "$(cat "${T}/ops.log")" "hello"
}
