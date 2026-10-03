#!/usr/bin/env bash
# aks-nodepool-upgrade.sh - controlled, zero-downtime AKS version upgrade.
#
# Order: control plane first (--control-plane-only), then node pools ONE AT A TIME
# with a max surge. After every step it waits for the operation, then checks a
# health gate before it moves on:
#   - every node is Ready and none is left cordoned
#   - every node in the upgraded pool runs the target kubelet version
#   - no Pod is stuck in Pending
# If a step fails or the gate does not pass in time, it stops and lists what is left.
#
# DRY RUN BY DEFAULT: it prints versions, the plan and the pre-flight health gate.
# Nothing changes without --apply (and a confirmation, or --yes).
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} -g RESOURCE_GROUP -n CLUSTER [-k VERSION] [options]

Without -k: show the current versions, node pools and available upgrades, then exit.
With -k:    plan an upgrade to VERSION (dry run), or run it with --apply.

Options:
  -g, --resource-group RG     Resource group of the cluster (required)
  -n, --name CLUSTER          AKS cluster name (required)
  -k, --kubernetes-version V  Target Kubernetes version, for example 1.30.4
  --control-plane-only        Upgrade only the control plane, not the node pools
  --nodepools-only            Skip the control plane (it must already run VERSION)
  --nodepool NAME             Upgrade only this pool (repeatable; pools run in the given order).
                              Default: every pool, System pools first, then User pools by name.
  --max-surge VALUE           Extra nodes during a pool upgrade, like 33% or 1 (default: 33%)
  --drain-timeout MINUTES     Pass --drain-timeout to the node pool upgrade (optional)
  --context NAME              kubectl context for the health checks (default: current context)
  --timeout DUR               Max wait for each upgrade operation (default: 90m)
  --settle-timeout DUR        Max wait for the health gate after each step (default: 10m)
  --poll-interval DUR         Time between status checks (default: 30s)
  --apply                     Really upgrade (otherwise: dry run)
  --yes                       Do not ask for confirmation with --apply
  --log-level LEVEL           debug|info|warn|error (default: info)
  -h, --help                  Show this help

Needs: az (logged in, right subscription selected), kubectl with access to the cluster, jq.
Exit codes: 0 ok, 1 error (operation failed or timed out), 2 usage, 3 missing tool,
            4 aborted, 6 health gate failed (stopped before the next step).
EOF
}

RG=""
CLUSTER=""
TARGET=""
CONTROL_PLANE_ONLY=false
NODEPOOLS_ONLY=false
declare -a ONLY_POOLS=()
MAX_SURGE="33%"
DRAIN_TIMEOUT=""
KUBE_CONTEXT=""
TIMEOUT=$((90 * 60))
SETTLE_TIMEOUT=$((10 * 60))
POLL=30
APPLY=false

parse_args() {
  while (($# > 0)); do
    case "$1" in
      -g | --resource-group) require_value "$1" "${2-}"; RG="$2"; shift 2 ;;
      -n | --name) require_value "$1" "${2-}"; CLUSTER="$2"; shift 2 ;;
      -k | --kubernetes-version)
        require_value "$1" "${2-}"
        [[ "$2" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage_error "$1 must look like 1.30.4, got '$2'"
        TARGET="$2"; shift 2 ;;
      --control-plane-only) CONTROL_PLANE_ONLY=true; shift ;;
      --nodepools-only) NODEPOOLS_ONLY=true; shift ;;
      --nodepool) require_value "$1" "${2-}"; ONLY_POOLS+=("$2"); shift 2 ;;
      --max-surge)
        require_value "$1" "${2-}"
        [[ "$2" =~ ^[1-9][0-9]*%?$ ]] || usage_error "--max-surge must be a number or a percentage like 33%, got '$2'"
        MAX_SURGE="$2"; shift 2 ;;
      --drain-timeout) require_value "$1" "${2-}"; require_int "$1" "$2"; DRAIN_TIMEOUT="$2"; shift 2 ;;
      --context) require_value "$1" "${2-}"; KUBE_CONTEXT="$2"; shift 2 ;;
      --timeout) require_value "$1" "${2-}"; TIMEOUT=$(require_duration "$1" "$2"); shift 2 ;;
      --settle-timeout) require_value "$1" "${2-}"; SETTLE_TIMEOUT=$(require_duration "$1" "$2"); shift 2 ;;
      --poll-interval) require_value "$1" "${2-}"; POLL=$(require_duration "$1" "$2"); shift 2 ;;
      --apply) APPLY=true; shift ;;
      --dry-run) APPLY=false; shift ;;
      --yes) ASSUME_YES=true; shift ;;
      --log-level) require_value "$1" "${2-}"; LOG_LEVEL="$2"; shift 2 ;;
      -h | --help) usage; exit 0 ;;
      *) usage_error "unknown option: $1" ;;
    esac
  done
  [[ -n "${RG}" ]] || usage_error "--resource-group is required"
  [[ -n "${CLUSTER}" ]] || usage_error "--name is required"
  if [[ "${CONTROL_PLANE_ONLY}" == true && "${NODEPOOLS_ONLY}" == true ]]; then
    usage_error "--control-plane-only and --nodepools-only cannot be used together"
  fi
  if [[ -z "${TARGET}" && ("${APPLY}" == true || "${CONTROL_PLANE_ONLY}" == true || "${NODEPOOLS_ONLY}" == true) ]]; then
    usage_error "--kubernetes-version is required to plan or apply an upgrade"
  fi
}

# ---------- kubectl ----------

kube() {
  local -a ctx=()
  [[ -n "${KUBE_CONTEXT}" ]] && ctx=(--context "${KUBE_CONTEXT}")
  "${KUBECTL_BIN:-kubectl}" "${ctx[@]}" --request-timeout=30s "$@"
}

# check_kube_context CLUSTER_JSON: make sure kubectl talks to THIS cluster, so the
# health gate never checks a different cluster by mistake.
check_kube_context() {
  local server host
  server=$(kube config view --minify -o json | jq -r '.clusters[0].cluster.server // ""') ||
    die "cannot read the kubectl context (use --context or 'az aks get-credentials')"
  host="${server#https://}"; host="${host%%:*}"; host="${host%%/*}"
  if ! jq -e --arg h "${host}" '[.fqdn, .privateFqdn, .azurePortalFqdn] | index($h) != null' <<<"$1" >/dev/null; then
    die "kubectl context points at '${host}', not at cluster ${CLUSTER} ($(jq -r '.fqdn // .privateFqdn' <<<"$1")). Use --context or 'az aks get-credentials -g ${RG} -n ${CLUSTER}'."
  fi
  log_info "kubectl context matches cluster ${CLUSTER} (${host})"
}

# gate_problems POOL VERSION: print one line per problem; nothing means healthy.
gate_problems() {
  local pool="$1" version="$2" nodes pods
  nodes=$(kube get nodes -o json) || { echo "kubectl get nodes failed"; return 0; }
  pods=$(kube get pods --all-namespaces --field-selector=status.phase=Pending -o json) ||
    { echo "kubectl get pods failed"; return 0; }
  jq -r --arg pool "${pool}" --arg want "v${version}" '
    .items[] | .metadata.name as $n
    | (.metadata.labels["kubernetes.azure.com/agentpool"] // .metadata.labels.agentpool // "") as $p
    | ([.status.conditions[]? | select(.type == "Ready") | .status][0] // "Unknown") as $ready
    | (if $ready != "True" then "node \($n) is not Ready (\($ready))" else empty end),
      (if .spec.unschedulable == true then "node \($n) is still cordoned" else empty end),
      (if $pool != "" and $p == $pool and .status.nodeInfo.kubeletVersion != $want
       then "node \($n) runs \(.status.nodeInfo.kubeletVersion), want \($want)" else empty end)' <<<"${nodes}"
  if [[ -n "${pool}" ]] && ! jq -e --arg pool "${pool}" \
    'any(.items[]; (.metadata.labels["kubernetes.azure.com/agentpool"] // .metadata.labels.agentpool) == $pool)' \
    <<<"${nodes}" >/dev/null; then
    echo "no nodes found for pool ${pool}"
  fi
  jq -r '.items[] | "pod \(.metadata.namespace)/\(.metadata.name) is Pending\(
    [.status.conditions[]? | select(.type == "PodScheduled" and .status == "False") | ": " + (.message // .reason // "")][0] // "")"' <<<"${pods}"
}

# health_gate LABEL POOL VERSION WAIT_SECONDS: poll until healthy or WAIT_SECONDS passed.
health_gate() {
  local label="$1" pool="$2" version="$3" wait="$4" start=${SECONDS} problems p
  while true; do
    problems=$(gate_problems "${pool}" "${version}")
    if [[ -z "${problems}" ]]; then
      log_info "health gate (${label}): all nodes Ready, no Pending pods"
      return 0
    fi
    if ((SECONDS - start >= wait)); then
      log_error "health gate (${label}) failed after $((SECONDS - start))s:"
      while IFS= read -r p; do log_error "  - ${p}"; done <<<"${problems}"
      return 1
    fi
    log_info "health gate (${label}): $(wc -l <<<"${problems}") problem(s), checking again in ${POLL}s"
    sleep "${POLL}"
  done
}

# warn_blocking_pdbs: a PodDisruptionBudget that allows 0 disruptions blocks node drain.
warn_blocking_pdbs() {
  local pdbs p
  pdbs=$(kube get poddisruptionbudgets --all-namespaces -o json) || { log_warn "could not list PodDisruptionBudgets"; return 0; }
  while IFS= read -r p; do
    [[ -n "${p}" ]] && log_warn "PodDisruptionBudget ${p} allows 0 disruptions now; it can block node drain"
  done < <(jq -r '.items[] | select((.status.disruptionsAllowed // 0) == 0) | "\(.metadata.namespace)/\(.metadata.name)"' <<<"${pdbs}")
}

# ---------- Azure operations ----------

# wait_provisioned LABEL az-args...: poll 'show' until provisioningState is Succeeded.
wait_provisioned() {
  local label="$1"; shift
  local start=${SECONDS} state
  while true; do
    state=$(az_cli "$@" | jq -r '.provisioningState // "Unknown"') || die "${label}: status check failed"
    case "${state}" in
      Succeeded) log_info "${label}: Succeeded after $((SECONDS - start))s"; return 0 ;;
      Failed | Canceled)
        die "${label}: provisioningState=${state}. See the cluster's Activity log in the portal and 'az aks show -g ${RG} -n ${CLUSTER}'." ;;
    esac
    if ((SECONDS - start >= TIMEOUT)); then
      die "${label}: still ${state} after $((SECONDS - start))s (--timeout). The operation keeps running in Azure; check it before you re-run."
    fi
    log_info "${label}: ${state}, checking again in ${POLL}s"
    sleep "${POLL}"
  done
}

upgrade_control_plane() {
  log_info "upgrading control plane to ${TARGET}"
  az_cli aks upgrade --resource-group "${RG}" --name "${CLUSTER}" --kubernetes-version "${TARGET}" \
    --control-plane-only --yes --no-wait >/dev/null || die "az aks upgrade failed to start"
  wait_provisioned "control plane" aks show --resource-group "${RG}" --name "${CLUSTER}"
  local now
  now=$(az_cli aks show --resource-group "${RG}" --name "${CLUSTER}" | jq -r '.currentKubernetesVersion // .kubernetesVersion')
  [[ "${now}" == "${TARGET}" ]] || die "control plane reports ${now} after the upgrade, expected ${TARGET}"
}

upgrade_pool() {
  local pool="$1"
  local -a extra=()
  [[ -n "${DRAIN_TIMEOUT}" ]] && extra=(--drain-timeout "${DRAIN_TIMEOUT}")
  log_info "upgrading node pool ${pool} to ${TARGET} (max surge ${MAX_SURGE})"
  az_cli aks nodepool upgrade --resource-group "${RG}" --cluster-name "${CLUSTER}" --name "${pool}" \
    --kubernetes-version "${TARGET}" --max-surge "${MAX_SURGE}" "${extra[@]}" --yes --no-wait >/dev/null ||
    die "az aks nodepool upgrade failed to start for ${pool}"
  wait_provisioned "node pool ${pool}" aks nodepool show --resource-group "${RG}" --cluster-name "${CLUSTER}" --name "${pool}"
}

main() {
  parse_args "$@"
  check_az_access

  local cluster upgrades pools current state
  cluster=$(az_cli aks show --resource-group "${RG}" --name "${CLUSTER}") || die "cannot read cluster ${RG}/${CLUSTER}"
  upgrades=$(az_cli aks get-upgrades --resource-group "${RG}" --name "${CLUSTER}") || die "az aks get-upgrades failed"
  pools=$(az_cli aks nodepool list --resource-group "${RG}" --cluster-name "${CLUSTER}") || die "az aks nodepool list failed"
  current=$(jq -r '.currentKubernetesVersion // .kubernetesVersion' <<<"${cluster}")
  state=$(jq -r '.provisioningState' <<<"${cluster}")

  printf 'Cluster %s/%s: control plane %s, state %s, power %s\n' "${RG}" "${CLUSTER}" "${current}" \
    "${state}" "$(jq -r '.powerState.code // "-"' <<<"${cluster}")"
  printf 'Available control plane upgrades: %s\n\n' "$(jq -r '
    [.controlPlaneProfile.upgrades[]? | .kubernetesVersion + (if .isPreview then " (preview)" else "" end)]
    | if length == 0 then "none" else join(", ") end' <<<"${upgrades}")"
  {
    printf 'POOL\tMODE\tVERSION\tNODES\tSTATE\tPOWER\tMAX_SURGE\n'
    jq -r '.[] | [.name, .mode, (.currentOrchestratorVersion // .orchestratorVersion), (.count // 0),
      .provisioningState, (.powerState.code // "-"), (.upgradeSettings.maxSurge // "default")] | @tsv' <<<"${pools}"
  } | print_table

  if [[ -z "${TARGET}" ]]; then
    printf '\nRe-run with -k VERSION to plan an upgrade.\n'
    return 0
  fi
  echo

  [[ "${state}" == Succeeded ]] || die "cluster provisioningState is ${state}; fix that before upgrading"
  [[ "$(jq -r '.powerState.code // "Running"' <<<"${cluster}")" == Running ]] || die "cluster is not running"

  # Control plane step.
  local do_cp=false
  if [[ "${current}" == "${TARGET}" ]]; then
    log_info "control plane already runs ${TARGET}"
  elif [[ "${NODEPOOLS_ONLY}" == true ]]; then
    usage_error "--nodepools-only: control plane runs ${current}; upgrade it to ${TARGET} first (node pools cannot be newer)"
  elif jq -e --arg v "${TARGET}" 'any(.controlPlaneProfile.upgrades[]?; .kubernetesVersion == $v)' <<<"${upgrades}" >/dev/null; then
    do_cp=true
  else
    usage_error "${TARGET} is not an available upgrade from ${current} (AKS does not skip minor versions); see the list above"
  fi

  # Node pool steps: given order, or System pools first then User pools by name.
  local -a order=() todo=() skipped=()
  local p
  if ((${#ONLY_POOLS[@]} > 0)); then
    for p in "${ONLY_POOLS[@]}"; do
      jq -e --arg p "${p}" 'any(.[]; .name == $p)' <<<"${pools}" >/dev/null || usage_error "node pool not found: ${p}"
      order+=("${p}")
    done
  else
    mapfile -t order < <(jq -r 'sort_by((if .mode == "System" then 0 else 1 end), .name) | .[].name' <<<"${pools}")
  fi
  if [[ "${CONTROL_PLANE_ONLY}" != true ]]; then
    for p in "${order[@]}"; do
      local info
      info=$(jq -c --arg p "${p}" '.[] | select(.name == $p)' <<<"${pools}")
      if [[ "$(jq -r '.currentOrchestratorVersion // .orchestratorVersion' <<<"${info}")" == "${TARGET}" ]]; then
        skipped+=("${p} (already ${TARGET})")
      elif [[ "$(jq -r '.powerState.code // "Running"' <<<"${info}")" != Running ]]; then
        skipped+=("${p} (stopped; start it or upgrade it later)")
      elif [[ "$(jq -r '.provisioningState' <<<"${info}")" != Succeeded ]]; then
        die "node pool ${p} is in state $(jq -r '.provisioningState' <<<"${info}"); fix that before upgrading"
      else
        todo+=("${p}")
      fi
    done
  fi

  # Plan.
  local step=0
  printf 'Plan (%s):\n' "$([[ "${APPLY}" == true ]] && echo apply || echo dry run)"
  if [[ "${do_cp}" == true ]]; then
    step=$((step + 1)); printf '  %d. control plane %s -> %s (--control-plane-only)\n' "${step}" "${current}" "${TARGET}"
  fi
  for p in "${todo[@]}"; do
    step=$((step + 1))
    printf '  %d. node pool %s %s -> %s, max surge %s, then health gate\n' "${step}" "${p}" \
      "$(jq -r --arg p "${p}" '.[] | select(.name == $p) | .currentOrchestratorVersion // .orchestratorVersion' <<<"${pools}")" \
      "${TARGET}" "${MAX_SURGE}"
  done
  for p in "${skipped[@]}"; do printf '  -  skip node pool %s\n' "${p}"; done
  printf 'Health gate: all nodes Ready and not cordoned, upgraded nodes on v%s, no Pending pods (wait up to %ss)\n\n' \
    "${TARGET}" "${SETTLE_TIMEOUT}"

  if ((step == 0)); then
    log_info "nothing to upgrade"
    return 0
  fi

  # Pre-flight (read-only, also in dry run): right cluster, healthy before we start.
  require_cmd "${KUBECTL_BIN:-kubectl}"
  check_kube_context "${cluster}"
  warn_blocking_pdbs
  health_gate "pre-flight" "" "" 0 || die "cluster is not healthy before the upgrade; fix the problems above first" "${EXIT_UNHEALTHY}"

  if [[ "${APPLY}" != true ]]; then
    log_info "dry run: ${step} step(s) planned. Re-run with --apply to upgrade."
    return 0
  fi
  confirm "Upgrade ${CLUSTER} to ${TARGET} (${step} step(s))?" || die "aborted by user" "${EXIT_ABORTED}"

  if [[ "${do_cp}" == true ]]; then
    upgrade_control_plane
    health_gate "after control plane" "" "" "${SETTLE_TIMEOUT}" ||
      die "stopping: health gate failed after the control plane upgrade; node pools not started: ${todo[*]:-none}" "${EXIT_UNHEALTHY}"
  fi
  local i
  for i in "${!todo[@]}"; do
    p="${todo[i]}"
    upgrade_pool "${p}"
    health_gate "after pool ${p}" "${p}" "${TARGET}" "${SETTLE_TIMEOUT}" ||
      die "stopping after pool ${p}; not started: $(rest="${todo[*]:i+1}"; echo "${rest:-none}")" "${EXIT_UNHEALTHY}"
  done
  log_info "upgrade to ${TARGET} complete (${step} step(s))"
}

main "$@"
