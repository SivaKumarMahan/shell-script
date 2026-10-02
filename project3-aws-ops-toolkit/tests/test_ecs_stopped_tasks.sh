#!/usr/bin/env bash
# Tests for ecs-stopped-tasks.sh against fixtures (LocalStack community has no ECS).

ecs() { "${TOOLKIT_DIR}/ecs-stopped-tasks.sh" "$@"; }

test_ecs_table_shows_recent_tasks_with_reasons() {
  run ecs --cluster prod
  assert_status 0
  assert_contains "${OUT}" "a1b2c3d4e5f6"                 # OOM task
  assert_contains "${OUT}" "app=137,log-router=0"
  assert_contains "${OUT}" "CannotPullContainerError"
  assert_contains "${OUT}" "SIGKILL: OOM"
  assert_contains "${OUT}" 'reason="OutOfMemoryError: Container killed due to memory usage"'
  assert_not_contains "${OUT}" "c3d4e5f60718"             # stopped 3h ago, outside 1h
  assert_contains "${OUT}" "api: 2 stopped (1x EssentialContainerExited, 1x TaskFailedToStart)"
  assert_contains "${OUT}" "worker: 2 stopped"
}

test_ecs_since_window_includes_older_tasks() {
  run ecs --cluster prod --since 4h --json
  assert_status 0
  assert_eq "$(jq length <<<"${OUT}")" "5"
  # newest first, timestamps normalised to UTC (input had +02:00 and epoch numbers)
  assert_eq "$(jq -r '.[0].stoppedAt' <<<"${OUT}")" "2026-09-30T11:55:00Z"
  assert_eq "$(jq -r '.[] | select(.task | startswith("b2c3")) | .stoppedAt' <<<"${OUT}")" "2026-09-30T11:40:00Z"
}

test_ecs_single_service_filter() {
  run ecs --cluster prod --service worker --json
  assert_status 0
  assert_eq "$(jq -r 'map(.service) | unique | join(",")' <<<"${OUT}")" "worker"
  assert_eq "$(count_calls 'ecs list-services')" "0"
}

test_ecs_no_stopped_tasks_message() {
  run ecs --cluster prod --service web
  assert_status 0
  assert_contains "${OUT}" "No tasks stopped in the last 1h"
}

test_ecs_describe_tasks_is_batched_by_100() {
  # Build a fixture set with 150 stopped tasks for one service.
  local fx="${T}/fixtures"
  mkdir -p "${fx}/ecs"
  jq -n '{serviceArns: ["arn:aws:ecs:eu-west-1:123456789012:service/prod/big"]}' >"${fx}/ecs/list-services.json"
  jq -n '{taskArns: [range(150) | "arn:aws:ecs:eu-west-1:123456789012:task/prod/t\(.)"]}' >"${fx}/ecs/list-tasks-big.json"
  jq -n '{tasks: [range(150) | {taskArn: "arn:aws:ecs:eu-west-1:123456789012:task/prod/t\(.)",
          group: "service:big", stopCode: "EssentialContainerExited", stoppedReason: "x",
          stoppedAt: "2026-09-30T11:59:00Z", containers: [{name: "app", exitCode: 1}]}]}' >"${fx}/ecs/describe-tasks.json"
  export MOCK_FIXTURES="${fx}"
  run ecs --cluster prod --json
  assert_status 0
  assert_eq "$(jq length <<<"${OUT}")" "150"
  assert_eq "$(count_calls 'ecs describe-tasks')" "2"
}

test_ecs_usage_errors() {
  run ecs
  assert_status 2
  assert_contains "${ERR}" "--cluster is required"
  run ecs --cluster prod --since soon
  assert_status 2
  run ecs --cluster
  assert_status 2
  run ecs --help
  assert_status 0
  assert_contains "${OUT}" "Usage:"
}
