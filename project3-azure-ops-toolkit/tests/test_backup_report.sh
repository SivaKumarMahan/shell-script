#!/usr/bin/env bash
# Tests for backup-report.sh with the mock az.
#
# Vault rsv-prod (now = 2026-09-30T12:00Z, default window 24h = since 09-29T12:00Z):
#   vm-app-01    Backup + Restore completed                    -> OK
#   vm-app-02    Backup failed 09-30 01:05 (and 09-28, outside) -> FAILED
#   vm-db-01     failed 09-29 22:00, completed 09-30 10:00      -> RECOVERED
#   sales        SQL backup completed with warnings             -> WARNING
#   vm-web-01    running since 11:30                            -> IN_PROGRESS
#   vm-batch-01  running since 01:00 (> 8h)                     -> LONG_RUNNING
#   vm-legacy-01 protected, no job                              -> NO_JOB
#   vm-old-01    protection stopped, no job                     -> not shown
# Vault rsv-ok has only vm-app-01.

backup() { "${TOOLKIT_DIR}/backup-report.sh" -g rg-backup "$@"; }
row() { grep -E "^$1 +$2 " <<<"${OUT}" || fail "no row '$1 $2'"; }

test_backup_failed_jobs_exit_5_with_details() {
  run backup -v rsv-prod
  assert_status 5
  row FAILED vm-app-02 >/dev/null
  row RECOVERED vm-db-01 >/dev/null
  row LONG_RUNNING vm-batch-01 >/dev/null
  row NO_JOB vm-legacy-01 >/dev/null
  row WARNING sales >/dev/null
  row IN_PROGRESS vm-web-01 >/dev/null
  row OK vm-app-01 >/dev/null
  assert_not_contains "${OUT}" "vm-old-01"
  assert_contains "$(row FAILED vm-app-02)" "UserErrorGuestAgentStatusUnavailable"
  assert_contains "${OUT}" "vm-app-02  Backup  2026-09-30T01:05:00Z  UserErrorGuestAgentStatusUnavailable: VM Agent unable"
  # the 09-28 failure is outside the window
  assert_not_contains "${OUT}" "old failure outside the window"
  assert_contains "${OUT}" "Summary: 7 item(s): 1 FAILED, 1 RECOVERED, 1 LONG_RUNNING, 1 NO_JOB, 1 WARNING, 1 IN_PROGRESS, 1 OK"
  assert_contains "${ERR}" "2 protected item(s) had failed backup jobs in the last 24h"
}

test_backup_asks_az_for_whole_days_around_the_window() {
  run backup -v rsv-prod --hours 36
  assert_contains "$(cat "${MOCK_STATE}/calls.log")" \
    "backup job list --resource-group rg-backup --vault-name rsv-prod --start-date 29-09-2026 --end-date 01-10-2026"
}

test_backup_warnings_only_fail_with_flag() {
  # last hour: only vm-web-01 has a job, everything else is NO_JOB
  run backup -v rsv-prod --hours 1
  assert_status 0
  assert_contains "${OUT}" "Summary: 7 item(s): 6 NO_JOB, 1 IN_PROGRESS"
  assert_contains "${ERR}" "6 protected item(s) need a look"
  run backup -v rsv-prod --hours 1 --fail-on-warnings
  assert_status 5
}

test_backup_max_running() {
  run backup -v rsv-prod --max-running 12h --json
  assert_status 5
  assert_eq "$(jq -r '.items[] | select(.item == "vm-batch-01") | .status' <<<"${OUT}")" "IN_PROGRESS"
}

test_backup_all_ok_exit_0() {
  run backup -v rsv-ok
  assert_status 0
  assert_contains "${OUT}" "OK      vm-app-01  VM    Restore         Completed"
  assert_contains "${OUT}" "Summary: 1 item(s): 1 OK"
  assert_not_contains "${OUT}" "Failed jobs"
}

test_backup_json_output() {
  run backup -v rsv-prod --json
  assert_status 5
  assert_eq "$(jq -r '.vault, .since, (.failedJobs | map(.item) | join(","))' <<<"${OUT}")" \
    $'rsv-prod\n2026-09-29T12:00:00Z\nvm-db-01,vm-app-02'
  assert_eq "$(jq -r '.items[0] | "\(.status) \(.item) \(.failed)"' <<<"${OUT}")" "FAILED vm-app-02 1"
}

test_backup_errors() {
  run backup -v missing-vault
  assert_status 1
  assert_contains "${ERR}" "cannot list backup jobs of rg-backup/missing-vault"
  run backup
  assert_status 2
  run backup -v rsv-prod --hours 0
  assert_status 2
  run backup -v rsv-prod --max-running forever
  assert_status 2
  run "${TOOLKIT_DIR}/backup-report.sh" -v rsv-prod
  assert_status 2
}
