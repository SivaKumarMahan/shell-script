#!/usr/bin/env bash
# Tests for aks-nodepool-upgrade.sh with the mock az and kubectl.
#
# Fixture cluster aks-prod: control plane 1.29.7, upgrades 1.30.3 / 1.30.4 / 1.30.5 (preview),
# pools "system" (System, 3 nodes), "apps" (User, 2 nodes) and "batch" (User, stopped).
# One PodDisruptionBudget (payments/payments-api-pdb) allows 0 disruptions.

aks() {
  "${TOOLKIT_DIR}/aks-nodepool-upgrade.sh" -g rg-aks-prod -n aks-prod --poll-interval 0s --settle-timeout 0s "$@"
}
upgrade_calls() { az_calls ' upgrade ' | sed -E 's/ --resource-group rg-aks-prod//; s/ --cluster-name aks-prod//'; }

test_aks_without_version_lists_versions_and_changes_nothing() {
  run aks
  assert_status 0
  assert_contains "${OUT}" "control plane 1.29.7"
  assert_contains "${OUT}" "Available control plane upgrades: 1.30.3, 1.30.4, 1.30.5 (preview)"
  assert_contains "${OUT}" "batch   User    1.29.7   0      Succeeded  Stopped"
  assert_eq "$(count_calls ' upgrade ')" "0"
  # listing does not need kubectl
  assert_eq "$(wc -l <"${MOCK_STATE}/kubectl-calls.log" | tr -d ' ')" "0"
}

test_aks_dry_run_is_default_and_runs_preflight() {
  run aks -k 1.30.4
  assert_status 0
  assert_contains "${OUT}" "Plan (dry run):"
  assert_contains "${OUT}" "1. control plane 1.29.7 -> 1.30.4 (--control-plane-only)"
  assert_contains "${OUT}" "2. node pool system 1.29.7 -> 1.30.4, max surge 33%"
  assert_contains "${OUT}" "3. node pool apps 1.29.7 -> 1.30.4"
  assert_contains "${OUT}" "skip node pool batch (stopped"
  assert_contains "${ERR}" "PodDisruptionBudget payments/payments-api-pdb allows 0 disruptions"
  assert_contains "${ERR}" "health gate (pre-flight): all nodes Ready"
  assert_contains "${ERR}" "dry run: 3 step(s) planned"
  assert_eq "$(count_calls ' upgrade ')" "0"
}

test_aks_apply_needs_confirmation_without_terminal() {
  run aks -k 1.30.4 --apply
  assert_status 4
  assert_eq "$(count_calls ' upgrade ')" "0"
}

test_aks_apply_upgrades_control_plane_first_then_pools_one_by_one() {
  run aks -k 1.30.4 --apply --yes --max-surge 50% --drain-timeout 45
  assert_status 0
  assert_eq "$(upgrade_calls)" "$(printf '%s\n' \
    'aks upgrade --name aks-prod --kubernetes-version 1.30.4 --control-plane-only --yes --no-wait' \
    'aks nodepool upgrade --name system --kubernetes-version 1.30.4 --max-surge 50% --drain-timeout 45 --yes --no-wait' \
    'aks nodepool upgrade --name apps --kubernetes-version 1.30.4 --max-surge 50% --drain-timeout 45 --yes --no-wait')"
  # each pool upgrade waits until the previous pool reports Succeeded
  local order
  order=$(grep -nE 'nodepool (upgrade|show)' "${MOCK_STATE}/calls.log" | sed -E 's/^([0-9]+):aks nodepool (upgrade|show) .*--name ([a-z]+).*/\2 \3/')
  assert_eq "${order}" $'upgrade system\nshow system\nshow system\nupgrade apps\nshow apps\nshow apps'
  assert_contains "${ERR}" "health gate (after pool system): all nodes Ready"
  assert_contains "${ERR}" "upgrade to 1.30.4 complete (3 step(s))"
}

test_aks_control_plane_only() {
  run aks -k 1.30.4 --control-plane-only --apply --yes
  assert_status 0
  assert_eq "$(count_calls '^aks upgrade .*--control-plane-only')" "1"
  assert_eq "$(count_calls 'nodepool upgrade')" "0"
}

test_aks_nodepools_only_and_pool_selection() {
  run aks -k 1.30.4 --nodepools-only
  assert_status 2
  assert_contains "${ERR}" "upgrade it to 1.30.4 first"
  # after the control plane is done, only the chosen pool runs
  aks -k 1.30.4 --control-plane-only --apply --yes 2>/dev/null >/dev/null
  run aks -k 1.30.4 --nodepools-only --nodepool apps --apply --yes
  assert_status 0
  assert_eq "$(count_calls 'nodepool upgrade')" "1"
  assert_eq "$(count_calls 'nodepool upgrade .*--name apps')" "1"
  run aks -k 1.30.4 --nodepool nope
  assert_status 2
  assert_contains "${ERR}" "node pool not found: nope"
}

test_aks_rejects_versions_that_are_not_offered() {
  run aks -k 1.31.1
  assert_status 2
  assert_contains "${ERR}" "1.31.1 is not an available upgrade from 1.29.7"
  run aks -k 1.30
  assert_status 2
  run aks -k 1.30.4 --max-surge 0
  assert_status 2
  run aks -k 1.30.4 --timeout soon
  assert_status 2
  run aks --apply
  assert_status 2
  run "${TOOLKIT_DIR}/aks-nodepool-upgrade.sh" -n aks-prod
  assert_status 2
}

test_aks_failed_pool_stops_before_next_pool() {
  export MOCK_FAIL_POOL=system
  run aks -k 1.30.4 --apply --yes
  assert_status 1
  assert_contains "${ERR}" "node pool system: provisioningState=Failed"
  assert_eq "$(count_calls 'nodepool upgrade .*--name apps')" "0"
}

test_aks_failed_control_plane_stops_everything() {
  export MOCK_CP_RESULT=Failed
  run aks -k 1.30.4 --apply --yes
  assert_status 1
  assert_contains "${ERR}" "control plane: provisioningState=Failed"
  assert_eq "$(count_calls 'nodepool upgrade')" "0"
}

test_aks_not_ready_node_after_pool_stops_with_exit_6() {
  export MOCK_NOTREADY_POOL=system
  run aks -k 1.30.4 --apply --yes
  assert_status 6
  assert_contains "${ERR}" "node aks-system-38214765-vmss000000 is not Ready (False)"
  assert_contains "${ERR}" "stopping after pool system; not started: apps"
  assert_eq "$(count_calls 'nodepool upgrade .*--name apps')" "0"
}

test_aks_pending_pod_after_pool_stops_with_exit_6() {
  export MOCK_PENDING_POOL=system
  run aks -k 1.30.4 --apply --yes
  assert_status 6
  assert_contains "${ERR}" "pod shop/cart-7d9f-abcde is Pending: 0/5 nodes are available: 2 Insufficient memory."
  assert_eq "$(count_calls 'nodepool upgrade .*--name apps')" "0"
}

test_aks_operation_timeout() {
  export MOCK_STUCK_POOL=system
  # --timeout 0s also applies to the control plane, so upgrade it first
  aks -k 1.30.4 --control-plane-only --apply --yes >/dev/null 2>&1
  run aks -k 1.30.4 --apply --yes --timeout 0s
  assert_status 1
  assert_contains "${ERR}" "node pool system: still Upgrading"
  assert_eq "$(count_calls 'nodepool upgrade .*--name apps')" "0"
}

test_aks_unhealthy_cluster_is_not_touched() {
  export MOCK_INITIAL_PENDING=1
  run aks -k 1.30.4
  assert_status 6
  assert_contains "${ERR}" "pod batch/report-1 is Pending"
  run aks -k 1.30.4 --apply --yes
  assert_status 6
  assert_eq "$(count_calls ' upgrade ')" "0"
}

test_aks_refuses_wrong_kubectl_context() {
  export MOCK_KUBE_SERVER=https://aks-dev-dns-99999999.hcp.westeurope.azmk8s.io:443
  run aks -k 1.30.4 --apply --yes
  assert_status 1
  assert_contains "${ERR}" "kubectl context points at 'aks-dev-dns-99999999.hcp.westeurope.azmk8s.io'"
  assert_eq "$(count_calls ' upgrade ')" "0"
}

test_aks_unknown_cluster() {
  run "${TOOLKIT_DIR}/aks-nodepool-upgrade.sh" -g rg-aks-prod -n missing
  assert_status 1
  assert_contains "${ERR}" "cannot read cluster rg-aks-prod/missing"
}
