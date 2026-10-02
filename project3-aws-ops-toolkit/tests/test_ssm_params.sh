#!/usr/bin/env bash
# Offline tests for ssm-params.sh with the mock CLI.
# The same flows run against real LocalStack in tests/integration/ssm-localstack.sh.

ssm() { "${TOOLKIT_DIR}/ssm-params.sh" "$@"; }

test_ssm_diff_masks_secure_strings() {
  run ssm diff --left /myapp/dev --right /myapp/stg
  assert_status 5
  assert_contains "${OUT}" 'CHANGED     db/host (String): "db.dev.internal" -> "db.stg.internal"'
  assert_contains "${OUT}" "db/password (SecureString): values differ"
  assert_contains "${OUT}" "ONLY_LEFT   only-dev (String)"
  assert_contains "${OUT}" "ONLY_RIGHT  only-stg (String)"
  assert_contains "${OUT}" "Summary: 4 difference(s), 1 identical"
  assert_not_contains "${OUT}${ERR}" "FAKE-secret"
}

test_ssm_diff_show_secrets() {
  run ssm diff --left /myapp/dev --right /myapp/stg --show-secrets
  assert_status 5
  assert_contains "${OUT}" '"dev-FAKE-secret-1" -> "stg-FAKE-secret-2"'
}

test_ssm_diff_identical_paths_exit_zero() {
  run ssm diff --left /myapp/dev --right /myapp/dev/
  assert_status 0
  assert_contains "${OUT}" "0 difference(s), 4 identical"
}

test_ssm_export_writes_private_file() {
  run ssm export --path /myapp/dev --file "${T}/dev.json"
  assert_status 0
  assert_eq "$(stat -c %a "${T}/dev.json")" "600"
  assert_eq "$(jq -r '.parameters | map(.name) | join(",")' "${T}/dev.json")" "db/host,db/password,feature/flags,only-dev"
  assert_not_contains "${OUT}${ERR}" "FAKE-secret"
  # refuses to overwrite without --force
  run ssm export --path /myapp/dev --file "${T}/dev.json"
  assert_status 1
  run ssm export --path /myapp/dev --file "${T}/dev.json" --force --skip-secure
  assert_status 0
  assert_eq "$(jq '[.parameters[] | select(.type == "SecureString")] | length' "${T}/dev.json")" "0"
}

test_ssm_import_dry_run_writes_nothing() {
  ssm export --path /myapp/dev --file "${T}/dev.json" 2>/dev/null
  run ssm import --path /myapp/new --file "${T}/dev.json" --dry-run
  assert_status 0
  assert_contains "${OUT}" "CREATE     /myapp/new/db/password (SecureString)"
  assert_contains "${OUT}" "4 to create"
  assert_eq "$(count_calls 'put-parameter')" "0"
}

test_ssm_import_never_puts_values_on_command_line() {
  ssm export --path /myapp/dev --file "${T}/dev.json" 2>/dev/null
  run ssm import --path /myapp/new --file "${T}/dev.json" --yes --kms-key-id alias/myapp
  assert_status 0
  assert_eq "$(wc -l <"${MOCK_STATE}/put-requests.jsonl" | tr -d ' ')" "4"
  assert_eq "$(jq -r 'select(.Name == "/myapp/new/db/password") | "\(.Type) \(.KeyId) \(.Overwrite)"' "${MOCK_STATE}/put-requests.jsonl")" \
    "SecureString alias/myapp false"
  assert_not_contains "$(cat "${MOCK_STATE}/calls.log")" "FAKE-secret"
  assert_not_contains "${OUT}${ERR}" "FAKE-secret"
}

test_ssm_import_skips_existing_without_overwrite() {
  ssm export --path /myapp/dev --file "${T}/dev.json" 2>/dev/null
  run ssm import --path /myapp/stg --file "${T}/dev.json" --dry-run
  assert_status 0
  assert_contains "${OUT}" "SKIP       /myapp/stg/db/host"
  assert_contains "${OUT}" "UNCHANGED  /myapp/stg/feature/flags"
  assert_contains "${OUT}" "CREATE     /myapp/stg/only-dev"
  run ssm import --path /myapp/stg --file "${T}/dev.json" --overwrite --yes
  assert_status 0
  assert_eq "$(jq -r 'select(.Name == "/myapp/stg/db/host") | .Overwrite' "${MOCK_STATE}/put-requests.jsonl")" "true"
}

test_ssm_import_rejects_bad_file() {
  echo '{"foo": 1}' >"${T}/bad.json"
  run ssm import --path /x --file "${T}/bad.json"
  assert_status 1
  assert_contains "${ERR}" "not a valid export file"
}

test_ssm_usage_errors() {
  run ssm
  assert_status 2
  run ssm export --path relative/path --file x
  assert_status 2
  run ssm diff --left /a
  assert_status 2
  run ssm frobnicate
  assert_status 2
  run ssm diff --help
  assert_status 0
}
