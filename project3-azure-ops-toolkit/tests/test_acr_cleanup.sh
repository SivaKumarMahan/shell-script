#!/usr/bin/env bash
# Tests for acr-cleanup.sh with the mock az.
#
# Fixture registry "acrplatform", repository "app" (now = 2026-09-30T12:00Z):
#   v1.0.1..v1.0.12 updated 2026-09-01..12 (v1.0.1 also "prod", v1.0.12 also "latest"),
#   a multi-arch index "multi-1.0.0" (09-15) with two untagged platform images,
#   two untagged orphans from August, and "legacy-1" (July) locked with deleteEnabled=false.
# Repository "api" has three recent tags; "empty" has no manifests.

acr() { "${TOOLKIT_DIR}/acr-cleanup.sh" --registry acrplatform "$@"; }
digest() { printf 'sha256:%s' "$(printf '%s' "$1" | sha256sum | cut -d' ' -f1)"; }
deleted() { sort "${MOCK_STATE}/deleted.txt" 2>/dev/null || true; }

test_acr_dry_run_is_default_and_deletes_nothing() {
  run acr --repository app
  assert_status 0
  assert_contains "${OUT}" "app: 4 to delete (186 MiB), 14 kept"
  assert_contains "${OUT}" "v1.0.2"
  assert_contains "${OUT}" "v1.0.3"
  assert_contains "${OUT}" "protected tag"
  assert_contains "${OUT}" "locked (deleteEnabled=false)"
  assert_contains "${OUT}" "platform image of a kept multi-arch tag"
  assert_contains "${ERR}" "dry run: 4 manifest(s) would be deleted"
  assert_eq "$(count_calls 'manifest delete')" "0"
}

test_acr_apply_needs_confirmation_without_terminal() {
  run acr --repository app --apply
  assert_status 4
  assert_eq "$(count_calls 'manifest delete')" "0"
}

test_acr_apply_deletes_exactly_the_planned_manifests() {
  run acr --repository app --apply --yes
  assert_status 0
  assert_eq "$(deleted)" "$(printf 'app@%s\n' "$(digest app-v2)" "$(digest app-v3)" "$(digest app-orphan-1)" "$(digest app-orphan-2)" | sort)"
  # never the protected, locked, newest or multi-arch platform images
  local d
  for d in app-v1 app-legacy app-v12 app-multi app-multi-amd64 app-multi-arm64; do
    assert_not_contains "$(deleted)" "$(digest "${d}")"
  done
  assert_contains "${ERR}" "deleted 4 manifest(s)"
}

test_acr_protect_pattern_keeps_release_tags() {
  run acr --repository app --protect '^v[0-9]' --apply --yes
  assert_status 0
  assert_eq "$(deleted)" "$(printf 'app@%s\n' "$(digest app-orphan-1)" "$(digest app-orphan-2)" | sort)"
}

test_acr_keep_older_than_and_untagged_only() {
  run acr --repository app --keep 15
  assert_status 0
  assert_contains "${OUT}" "app: 2 to delete"
  # cutoff 2026-09-02T12:00Z: v1.0.3 (09-03) is too new, v1.0.2 (09-02 10:00) is old enough
  run acr --repository app --older-than 28d
  assert_status 0
  assert_contains "${OUT}" "app: 3 to delete"
  assert_contains "${OUT}" "newer than --older-than"
  run acr --repository app --untagged-only --apply --yes
  assert_status 0
  assert_eq "$(wc -l <"${MOCK_STATE}/deleted.txt" | tr -d ' ')" "2"
}

test_acr_all_repositories() {
  run acr --all-repositories
  assert_status 0
  assert_contains "${OUT}" "api: 0 to delete"
  assert_contains "${OUT}" "app: 4 to delete"
  assert_eq "$(count_calls 'acr repository list --name acrplatform')" "1"
}

test_acr_partial_failure_returns_error_but_continues() {
  export MOCK_FAIL_DIGEST
  MOCK_FAIL_DIGEST=$(digest app-orphan-1)
  run acr --repository app --apply --yes
  assert_status 1
  assert_contains "${ERR}" "1 manifest(s) could not be deleted (3 deleted)"
  assert_eq "$(wc -l <"${MOCK_STATE}/deleted.txt" | tr -d ' ')" "3"
}

test_acr_empty_repo_and_errors() {
  run acr --repository empty
  assert_status 0
  assert_contains "${ERR}" "nothing to delete"
  run acr --repository missing
  assert_status 1
  assert_contains "${ERR}" "cannot list manifests of acrplatform/missing"
  run acr --repository app --keep 0
  assert_status 2
  run acr --repository app --protect '('
  assert_status 2
  run acr --repository app --older-than 3w
  assert_status 2
  run acr --repository app --all-repositories
  assert_status 2
  run acr
  assert_status 2
  run "${TOOLKIT_DIR}/acr-cleanup.sh" --repository app
  assert_status 2
}
