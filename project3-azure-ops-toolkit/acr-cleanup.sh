#!/usr/bin/env bash
# acr-cleanup.sh - keep the N most recent tagged images per ACR repository,
# delete older and untagged manifests.
#
# DRY RUN BY DEFAULT: it prints a plan. Nothing is deleted without --apply
# (and a confirmation, or --yes).
#
# Safety rules (a manifest is KEPT if any rule matches):
#   - it is one of the newest --keep tagged manifests (rollback window)
#   - one of its tags matches --protect (regex), for example '^v[0-9]' for releases
#   - it is locked (deleteEnabled=false, set with 'az acr repository update --delete-enabled false')
#   - with --older-than: it was updated more recently than that
#   - it is an untagged platform image of a kept multi-arch image (manifest list / OCI index);
#     deleting it would break 'docker pull' for that tag
#
# Deleting a manifest also deletes all of its tags. For steady-state cleanup prefer a
# scheduled 'acr purge' task or the ACR retention policy for untagged manifests; this
# script is for previews, one-off cleanups and rules those tools cannot express.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} --registry NAME (--repository NAME... | --all-repositories) [options]

Clean up repositories in an Azure Container Registry. Dry run by default.

Options:
  --registry NAME      Registry name, without .azurecr.io (required)
  --repository NAME    Repository to clean (repeatable)
  --all-repositories   Clean every repository in the registry
  --keep N             Keep the N most recent tagged manifests per repository (default: 10, minimum 1)
  --protect REGEX      Never delete manifests with a tag matching REGEX (repeatable), e.g. '^v[0-9]'.
                       Adds to the built-in rule '^(latest|prod|production|stable)$'.
  --older-than DUR     Only delete manifests last updated before DUR ago, for example 30d
  --untagged-only      Only delete untagged manifests
  --apply              Really delete (otherwise: dry run)
  --yes                Do not ask for confirmation with --apply
  --show-kept          Also list every kept manifest in the plan
  --log-level LEVEL    debug|info|warn|error (default: info)
  -h, --help           Show this help

Needs: az (logged in; role AcrDelete or Contributor on the registry for --apply), jq.
Exit codes: 0 ok, 1 error (or some deletes failed), 2 usage, 3 missing tool, 4 aborted.
EOF
}

REGISTRY=""
declare -a REPOS=()
ALL_REPOS=false
KEEP=10
OLDER_THAN=""
PROTECT='^(latest|prod|production|stable)$'  # extra --protect rules are added with '|'
UNTAGGED_ONLY=false
APPLY=false
SHOW_KEPT=false

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --registry) require_value "$1" "${2-}"; REGISTRY="${2%.azurecr.io}"; shift 2 ;;
      --repository) require_value "$1" "${2-}"; REPOS+=("$2"); shift 2 ;;
      --all-repositories) ALL_REPOS=true; shift ;;
      --keep) require_value "$1" "${2-}"; require_int "$1" "$2"; KEEP="$2"; shift 2 ;;
      --older-than) require_value "$1" "${2-}"; OLDER_THAN=$(require_duration "$1" "$2"); shift 2 ;;
      --protect) require_value "$1" "${2-}"; require_regex "$1" "$2"; PROTECT="${PROTECT}|(${2})"; shift 2 ;;
      --untagged-only) UNTAGGED_ONLY=true; shift ;;
      --apply) APPLY=true; shift ;;
      --dry-run) APPLY=false; shift ;;
      --yes) ASSUME_YES=true; shift ;;
      --show-kept) SHOW_KEPT=true; shift ;;
      --log-level) require_value "$1" "${2-}"; LOG_LEVEL="$2"; shift 2 ;;
      -h | --help) usage; exit 0 ;;
      *) usage_error "unknown option: $1" ;;
    esac
  done
  [[ -n "${REGISTRY}" ]] || usage_error "--registry is required"
  if [[ "${ALL_REPOS}" == true && ${#REPOS[@]} -gt 0 ]]; then
    usage_error "use --repository or --all-repositories, not both"
  fi
  [[ "${ALL_REPOS}" == true || ${#REPOS[@]} -gt 0 ]] || usage_error "--repository or --all-repositories is required"
  ((KEEP >= 1)) || usage_error "--keep must be at least 1"
}

# plan_repo REPO PLAN_FILE TMPDIR: writes a JSON array of manifests with action and reason.
plan_repo() {
  local repo="$1" plan="$2" tmp="$3" cutoff="null"
  local raw="${tmp}/raw.json"

  log_info "reading manifests in ${REGISTRY}/${repo}"
  az_cli acr manifest list-metadata --registry "${REGISTRY}" --name "${repo}" >"${raw}" ||
    die "cannot list manifests of ${REGISTRY}/${repo}"
  if [[ -n "${OLDER_THAN}" ]]; then
    cutoff=$(($(now_epoch) - OLDER_THAN))
  fi

  # Step 1: decide for tagged manifests; untagged ones stay "candidate" for now.
  jq --argjson keep "${KEEP}" --argjson cutoff "${cutoff}" --arg protect "${PROTECT}" \
    --argjson untagged_only "${UNTAGGED_ONLY}" "${JQ_DEFS}"'
    def is_index: (.mediaType // "") | test("manifest\\.list|image\\.index");
    [ .[] | {
        digest,
        tags: (.tags // []),
        updated: ((.lastUpdateTime // .createdTime) | epoch),
        size: (.imageSize // 0),
        index: is_index,
        locked: (.changeableAttributes.deleteEnabled == false) } ]
    | (map(select(.tags | length > 0)) | sort_by(-.updated)) as $tagged
    | (map(select(.tags | length == 0))) as $untagged
    | [ $tagged | to_entries[] | .key as $i | .value
        | . + (if $i < $keep then {action: "keep", reason: "newest \($keep)"}
               elif any(.tags[]; test($protect)) then {action: "keep", reason: "protected tag"}
               elif .locked then {action: "keep", reason: "locked (deleteEnabled=false)"}
               elif $untagged_only then {action: "keep", reason: "tagged (--untagged-only)"}
               elif $cutoff != null and .updated >= $cutoff then {action: "keep", reason: "newer than --older-than"}
               else {action: "delete", reason: "beyond newest \($keep)"} end) ]
      + [ $untagged[] | . + {action: "candidate", reason: "untagged"} ]' "${raw}" >"${plan}"

  # Step 2: keep the platform images of kept multi-arch images.
  local -a idx=()
  local d
  mapfile -t idx < <(jq -r '.[] | select(.index and .action == "keep") | .digest' "${plan}")
  : >"${tmp}/children.txt"
  for d in "${idx[@]}"; do
    az_cli acr manifest show --registry "${REGISTRY}" --name "${repo}@${d}" |
      jq -r '.manifests[]?.digest' >>"${tmp}/children.txt" || die "cannot read manifest ${repo}@${d}"
  done
  ((${#idx[@]} == 0)) || log_info "${repo}: ${#idx[@]} kept multi-arch image(s); their platform images are kept too"

  jq --rawfile children "${tmp}/children.txt" --argjson cutoff "${cutoff}" '
    ($children | split("\n") | map(select(length > 0))) as $kids
    | map(if .action != "candidate" then .
          elif (.digest | IN($kids[])) then .action = "keep" | .reason = "platform image of a kept multi-arch tag"
          elif .locked then .action = "keep" | .reason = "locked (deleteEnabled=false)"
          elif $cutoff != null and .updated >= $cutoff then .action = "keep" | .reason = "newer than --older-than"
          else .action = "delete" end)' "${plan}" >"${plan}.new"
  mv -f -- "${plan}.new" "${plan}"
}

print_plan() {
  local repo="$1" plan="$2" rows
  rows=$(jq -r --argjson show_kept "${SHOW_KEPT}" "${JQ_DEFS}"'
    def mib: . / 1048576 * 10 | round / 10;
    # Kept manifests are shown only with --show-kept, or when a safety rule kept them.
    .[] | select(.action == "delete" or $show_kept or (.reason | startswith("newest ") | not))
    | [ (.action | ascii_upcase), .digest[0:19],
        (if (.tags | length) == 0 then "<untagged>" else (.tags | join(",")) end),
        (.updated | utc), "\(.size | mib) MiB", .reason ] | @tsv' "${plan}")
  if [[ -n "${rows}" ]]; then
    printf 'ACTION\tDIGEST\tTAGS\tUPDATED (UTC)\tSIZE\tREASON\n%s\n' "${rows}" | print_table
  fi
  jq -r --arg repo "${repo}" '
    (map(select(.action == "delete"))) as $d
    | "\($repo): \($d | length) to delete (\(($d | map(.size) | add // 0) / 1048576 | round) MiB), \(map(select(.action == "keep")) | length) kept"' "${plan}"
}

main() {
  parse_args "$@"
  check_az_access
  local tmp repo plan to_delete=0 n i=0
  make_tmpdir tmp

  if [[ "${ALL_REPOS}" == true ]]; then
    local list
    list=$(az_cli acr repository list --name "${REGISTRY}") || die "cannot list repositories in ${REGISTRY}"
    mapfile -t REPOS < <(jq -r '.[]' <<<"${list}")
    ((${#REPOS[@]} > 0)) || { log_info "registry ${REGISTRY} has no repositories"; return 0; }
  fi

  declare -A PLANS=()
  for repo in "${REPOS[@]}"; do
    i=$((i + 1))
    plan="${tmp}/plan-${i}.json"
    PLANS["${repo}"]="${plan}"
    plan_repo "${repo}" "${plan}" "${tmp}"
    printf '\n== %s/%s ==\n' "${REGISTRY}" "${repo}"
    print_plan "${repo}" "${plan}"
    n=$(jq 'map(select(.action == "delete")) | length' "${plan}")
    to_delete=$((to_delete + n))
  done
  echo

  if ((to_delete == 0)); then
    log_info "nothing to delete"
    return 0
  fi
  if [[ "${APPLY}" != true ]]; then
    log_info "dry run: ${to_delete} manifest(s) would be deleted. Re-run with --apply to delete them."
    return 0
  fi
  confirm "Delete ${to_delete} manifest(s) (and their tags) from ${REGISTRY}?" || die "aborted by user" "${EXIT_ABORTED}"

  # One call per manifest (ACR has no batch delete). Keep going on errors, report at the end.
  local failures=0 deleted=0 d
  for repo in "${REPOS[@]}"; do
    while IFS= read -r d; do
      if az_cli acr manifest delete --registry "${REGISTRY}" --name "${repo}@${d}" --yes >/dev/null; then
        deleted=$((deleted + 1))
        log_info "deleted ${repo}@${d}"
      else
        failures=$((failures + 1))
        log_error "failed to delete ${repo}@${d}"
      fi
    done < <(jq -r '.[] | select(.action == "delete") | .digest' "${PLANS[${repo}]}")
  done
  ((failures == 0)) || die "${failures} manifest(s) could not be deleted (${deleted} deleted)"
  log_info "deleted ${deleted} manifest(s)"
}

main "$@"
