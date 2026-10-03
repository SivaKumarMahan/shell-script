#!/usr/bin/env bash
# Tests for keyvault-secrets.sh with the mock az.
#
# Fixture vaults (now = 2026-09-30T12:00Z):
#   kv-app-dev:  api-key (expired 09-25), db-password (expires 10-10), feature-flag-x (no expiry),
#                old-token (disabled), redis-password (2027), storage-conn (no expiry, text/plain)
#   kv-app-prod: same names minus feature-flag-x, plus prod-only-key; db-password has another value,
#                old-token is enabled, storage-conn has no content type.
# Every fixture value starts with "FAKE-", so a test can grep for leaks.

kv() { "${TOOLKIT_DIR}/keyvault-secrets.sh" "$@"; }

test_kv_list_shows_metadata_but_never_values() {
  run kv list --vault kv-app-dev
  assert_status 0
  assert_contains "${OUT}" "db-password     true     2026-10-10T00:00:00Z  9"
  assert_contains "${OUT}" "old-token       false"
  assert_contains "${OUT}" "storage-conn    true     -                     -          text/plain"
  assert_not_contains "${OUT}${ERR}" "FAKE-"
  # metadata only: no 'secret show' call at all
  assert_eq "$(count_calls 'secret show')" "0"
}

test_kv_list_show_values_prints_values_and_skips_disabled() {
  run kv list --vault kv-app-dev --show-values
  assert_status 0
  assert_contains "${OUT}" "FAKE-dev-db-pass"
  assert_contains "${OUT}" "<disabled>"
  assert_contains "${ERR}" "--show-values: secret values will be printed"
  # a disabled secret cannot be read, so it is not even requested
  assert_eq "$(count_calls 'secret show .*--name old-token')" "0"
}

test_kv_list_json() {
  run kv list --vault kv-app-dev --json
  assert_status 0
  assert_eq "$(jq -r '[.[] | select(.enabled | not) | .name] | join(",")' <<<"${OUT}")" "old-token"
  assert_eq "$(jq 'map(has("value")) | any' <<<"${OUT}")" "false"
}

test_kv_diff_by_name_and_metadata() {
  run kv diff --left kv-app-dev --right kv-app-prod
  assert_status 5
  assert_contains "${OUT}" "ONLY_LEFT   feature-flag-x"
  assert_contains "${OUT}" "ONLY_RIGHT  prod-only-key"
  assert_contains "${OUT}" "CHANGED     old-token: enabled false -> true"
  assert_contains "${OUT}" 'CHANGED     storage-conn: contentType "text/plain" -> ""'
  assert_contains "${OUT}" "Summary: 4 difference(s), 3 identical"
  assert_not_contains "${OUT}" "db-password"
  assert_eq "$(count_calls 'secret show')" "0"
}

test_kv_diff_compare_values_masks_values_and_hashes() {
  run kv diff --left kv-app-dev --right kv-app-prod --compare-values
  assert_status 5
  assert_contains "${OUT}" "CHANGED     db-password: value differs"
  assert_contains "${OUT}" "old-token: enabled false -> true; value not compared (disabled)"
  assert_contains "${OUT}" "Summary: 5 difference(s), 2 identical"
  assert_not_contains "${OUT}${ERR}" "FAKE-"
  # not even the hash is printed
  local h
  h=$(printf '%s' "FAKE-dev-db-pass" | sha256sum | cut -d' ' -f1)
  assert_not_contains "${OUT}${ERR}" "${h}"
  # values travel through pipes only, never through the command line
  assert_not_contains "$(cat "${MOCK_STATE}/calls.log")" "FAKE-"
}

test_kv_diff_show_values() {
  run kv diff --left kv-app-dev --right kv-app-prod --show-values
  assert_status 5
  assert_contains "${OUT}" 'db-password: value "FAKE-dev-db-pass" -> "FAKE-prod-db-pass"'
  # identical values are still not printed
  assert_not_contains "${OUT}" "FAKE-api-key-shared"
}

test_kv_diff_identical_vaults_exit_zero() {
  run kv diff --left kv-app-prod --right kv-app-prod --compare-values
  assert_status 0
  assert_contains "${OUT}" "Summary: 0 difference(s), 6 identical"
}

test_kv_expiring_exit_code_for_alerting() {
  run kv expiring --vault kv-app-dev
  assert_status 5
  assert_contains "${OUT}" "EXPIRED   api-key      2026-09-25T00:00:00Z  -6"
  assert_contains "${OUT}" "EXPIRING  db-password  2026-10-10T00:00:00Z  9"
  assert_not_contains "${OUT}" "old-token"     # disabled secrets are ignored
  assert_contains "${OUT}" "Summary: 1 expired, 1 expiring, 0 without expiry"
  run kv expiring --vault kv-app-prod --days 7
  assert_status 0
  assert_contains "${OUT}" "Summary: 0 expired, 0 expiring, 0 without expiry"
}

test_kv_expiring_include_no_expiry_json() {
  run kv expiring --vault kv-app-dev --days 5 --include-no-expiry --json
  assert_status 5
  assert_eq "$(jq -r 'map("\(.status):\(.name)") | join(",")' <<<"${OUT}")" \
    "EXPIRED:api-key,NO_EXPIRY:feature-flag-x,NO_EXPIRY:storage-conn"
}

test_kv_export_metadata_only_private_file() {
  run kv export --vault kv-app-dev --file "${T}/dev.secrets.json"
  assert_status 0
  assert_eq "$(stat -c %a "${T}/dev.secrets.json")" "600"
  assert_eq "$(jq -r '.includesValues, (.secrets | length)' "${T}/dev.secrets.json")" $'false\n6'
  assert_not_contains "$(cat "${T}/dev.secrets.json")" "FAKE-"
  # refuses to overwrite without --force
  run kv export --vault kv-app-dev --file "${T}/dev.secrets.json"
  assert_status 1
  assert_contains "${ERR}" "already exists"
  run kv export --vault kv-app-dev --file "${T}/dev.secrets.json" --force --show-values
  assert_status 0
  assert_eq "$(jq -r '.secrets[] | select(.name == "db-password") | .value' "${T}/dev.secrets.json")" "FAKE-dev-db-pass"
  assert_eq "$(stat -c %a "${T}/dev.secrets.json")" "600"
  assert_not_contains "${OUT}${ERR}" "FAKE-"
}

test_kv_errors() {
  run kv list --vault missing-kv
  assert_status 1
  assert_contains "${ERR}" "cannot list secrets in missing-kv"
  run kv
  assert_status 2
  run kv rotate --vault kv-app-dev
  assert_status 2
  run kv diff --left kv-app-dev
  assert_status 2
  run kv expiring --vault kv-app-dev --days soon
  assert_status 2
  run kv export --vault kv-app-dev
  assert_status 2
  run kv list --vault kv-app-dev --bogus
  assert_status 2
}
