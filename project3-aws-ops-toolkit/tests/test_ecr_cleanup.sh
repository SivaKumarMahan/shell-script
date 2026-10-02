#!/usr/bin/env bash
# Tests for ecr-cleanup.sh against fixtures (LocalStack community has no ECR).
#
# Fixture repo "app": v1.0.1..v1.0.12 pushed 2026-09-01..12 (v1.0.1 also tagged "prod",
# v1.0.12 also "latest"), a multi-arch index "multi-1.0.0" (2026-09-15) with two untagged
# platform images, and two untagged orphans from August.

ecr() { "${TOOLKIT_DIR}/ecr-cleanup.sh" "$@"; }
digest() { printf 'sha256:%s' "$(printf '%s' "$1" | sha256sum | cut -d' ' -f1)"; }

test_ecr_dry_run_is_default_and_deletes_nothing() {
  run ecr --repository app
  assert_status 0
  assert_contains "${OUT}" "app: 4 to delete"
  assert_contains "${OUT}" "v1.0.2"
  assert_contains "${OUT}" "v1.0.3"
  assert_contains "${OUT}" "protected tag"
  assert_contains "${OUT}" "platform image of a kept multi-arch tag"
  assert_contains "${ERR}" "dry run: 4 image(s) would be deleted"
  assert_eq "$(count_calls 'batch-delete-image')" "0"
}

test_ecr_apply_needs_confirmation_without_terminal() {
  run ecr --repository app --apply
  assert_status 4
  assert_eq "$(count_calls 'batch-delete-image')" "0"
}

test_ecr_apply_deletes_exactly_the_planned_images() {
  run ecr --repository app --apply --yes
  assert_status 0
  local deleted
  deleted=$(sort "${MOCK_STATE}/deleted.txt")
  local expected
  expected=$(printf '%s\n' "$(digest app-v2)" "$(digest app-v3)" "$(digest app-orphan-1)" "$(digest app-orphan-2)" | sort)
  assert_eq "${deleted}" "${expected}"
  # never the protected image, the newest images or the multi-arch children
  assert_not_contains "${deleted}" "$(digest app-v1)"
  assert_not_contains "${deleted}" "$(digest app-multi-amd64)"
  assert_not_contains "${deleted}" "$(digest app-multi-arm64)"
}

test_ecr_older_than_keeps_recent_images() {
  # now = 2026-09-30T12:00Z, 28d -> cutoff 2026-09-02T12:00Z: v1.0.3 (09-03) is too new.
  run ecr --repository app --older-than 28d --apply --yes
  assert_status 0
  assert_contains "$(cat "${MOCK_STATE}/deleted.txt")" "$(digest app-v2)"
  assert_not_contains "$(cat "${MOCK_STATE}/deleted.txt")" "$(digest app-v3)"
}

test_ecr_untagged_only() {
  run ecr --repository app --untagged-only --apply --yes
  assert_status 0
  assert_eq "$(wc -l <"${MOCK_STATE}/deleted.txt" | tr -d ' ')" "2"
}

test_ecr_keep_and_protect_options() {
  run ecr --repository app --keep 13
  assert_status 0
  assert_contains "${OUT}" "app: 2 to delete"     # only the orphans
  run ecr --repository app --protect '^v1\.0\.(2|3)$'
  assert_status 0
  assert_contains "${OUT}" "app: 2 to delete"
}

test_ecr_partial_failure_returns_error() {
  export MOCK_FAIL_DIGEST
  MOCK_FAIL_DIGEST=$(digest app-orphan-1)
  run ecr --repository app --apply --yes
  assert_status 1
  assert_contains "${ERR}" "1 image(s) could not be deleted"
}

test_ecr_batches_deletes_by_100() {
  local fx="${T}/fixtures"
  mkdir -p "${fx}/ecr"
  jq -n '{imageDetails: [range(250) | {imageDigest: "sha256:\(.)", imagePushedAt: "2026-08-01T00:00:00Z",
          imageSizeInBytes: 1}]}' >"${fx}/ecr/describe-images-big.json"
  export MOCK_FIXTURES="${fx}"
  run ecr --repository big --apply --yes
  assert_status 0
  assert_eq "$(count_calls 'batch-delete-image')" "3"
  assert_eq "$(wc -l <"${MOCK_STATE}/deleted.txt" | tr -d ' ')" "250"
}

test_ecr_empty_repo_and_errors() {
  run ecr --repository empty
  assert_status 0
  assert_contains "${ERR}" "nothing to delete"
  run ecr --repository missing
  assert_status 1
  run ecr --repository app --keep 0
  assert_status 2
  run ecr --repository app --protect '('
  assert_status 2
  run ecr
  assert_status 2
}
