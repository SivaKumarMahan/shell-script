#!/usr/bin/env bash
# ecr-cleanup.sh - delete untagged images and old images beyond the N most recent.
#
# DRY RUN BY DEFAULT: it prints a plan. Nothing is deleted without --apply
# (and a confirmation, or --yes).
#
# Safety rules:
#   - the newest --keep tagged images are always kept (rollback window)
#   - tags matching --protect (regex) are always kept
#   - with --older-than, only images older than that age are deleted
#   - untagged images that belong to a kept multi-arch image (manifest list / OCI index)
#     are kept: deleting them would break 'docker pull' for that tag
#
# For steady-state cleanup prefer an ECR lifecycle policy; this script is for one-off
# cleanups, previews and repos where lifecycle rules are not enough.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} --repository NAME [--repository NAME]... [options]

Clean up an ECR repository. Dry run by default.

Options:
  --repository NAME    Repository to clean (repeatable, required)
  --keep N             Keep the N most recent tagged images (default: 10, minimum 1)
  --older-than DUR     Only delete tagged images older than DUR, for example 30d
  --protect REGEX      Never delete images with a tag matching REGEX (repeatable).
                       Adds to the built-in rule '^(latest|prod|production|stable)$'.
  --untagged-only      Only delete untagged images
  --apply              Really delete (otherwise: dry run)
  --yes                Do not ask for confirmation with --apply
  --show-kept          Also list every kept image in the plan
  --log-level LEVEL    debug|info|warn|error (default: info)
  -h, --help           Show this help

Environment: AWS_PROFILE, AWS_REGION, AWS_ENDPOINT_URL, LOG_LEVEL, LOG_FILE.
Exit codes: 0 ok, 1 error (or some deletes failed), 2 usage, 3 missing tool, 4 aborted.
EOF
}

declare -a REPOS=()
KEEP=10
OLDER_THAN=""
PROTECT='^(latest|prod|production|stable)$'  # extra --protect rules are added with '|'
UNTAGGED_ONLY=false
APPLY=false
SHOW_KEPT=false

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --repository) require_value "$1" "${2-}"; REPOS+=("$2"); shift 2 ;;
      --keep) require_value "$1" "${2-}"; require_int "$1" "$2"; KEEP="$2"; shift 2 ;;
      --older-than) require_value "$1" "${2-}"; OLDER_THAN="$2"; shift 2 ;;
      --protect)
        require_value "$1" "${2-}"
        jq -n --arg re "$2" '"x" | test($re)' >/dev/null 2>&1 || usage_error "--protect is not a valid regex: $2"
        PROTECT="${PROTECT}|(${2})"
        shift 2 ;;
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
  ((${#REPOS[@]} > 0)) || usage_error "at least one --repository is required"
  ((KEEP >= 1)) || usage_error "--keep must be at least 1"
  if [[ -n "${OLDER_THAN}" ]]; then
    parse_duration "${OLDER_THAN}" >/dev/null || usage_error "--older-than must look like 30d or 12h"
  fi
}

# plan_repo REPO TMPDIR: writes TMPDIR/plan-REPO.json (array of images with action and reason).
plan_repo() {
  local repo="$1" tmp="$2" cutoff="null"
  local images="${tmp}/images-${repo//\//_}.json" plan="${tmp}/plan-${repo//\//_}.json"

  log_info "reading images in ${repo}"
  aws_cli ecr describe-images --repository-name "${repo}" >"${images}" || die "describe-images failed for ${repo}"

  if [[ -n "${OLDER_THAN}" ]]; then
    cutoff=$(($(now_epoch) - $(parse_duration "${OLDER_THAN}")))
  fi

  # Step 1: decide for tagged images; untagged ones are "candidate" for now.
  jq --argjson keep "${KEEP}" --argjson cutoff "${cutoff}" --arg protect "${PROTECT}" \
    --argjson untagged_only "${UNTAGGED_ONLY}" "${JQ_DEFS}"'
    def is_index: (.imageManifestMediaType // "") | test("manifest\\.list|image\\.index");
    [.imageDetails[] | {
        digest: .imageDigest,
        tags: (.imageTags // []),
        pushed: (.imagePushedAt | epoch),
        size: (.imageSizeInBytes // 0),
        index: is_index
    }]
    | (map(select(.tags | length > 0)) | sort_by(-.pushed)) as $tagged
    | (map(select(.tags | length == 0))) as $untagged
    | [ $tagged | to_entries[] | .key as $i | .value
        | . + (if $i < $keep then {action: "keep", reason: "newest \($keep)"}
               elif any(.tags[]; test($protect)) then {action: "keep", reason: "protected tag"}
               elif $untagged_only then {action: "keep", reason: "tagged (--untagged-only)"}
               elif $cutoff != null and .pushed >= $cutoff then {action: "keep", reason: "newer than --older-than"}
               else {action: "delete", reason: "beyond newest \($keep)"} end) ]
      + [ $untagged[] | . + {action: "candidate", reason: "untagged"} ]' "${images}" >"${plan}"

  # Step 2: protect child manifests of kept multi-arch images.
  local -a idx=()
  mapfile -t idx < <(jq -r '.[] | select(.index and .action == "keep") | .digest' "${plan}")
  : >"${tmp}/children.txt"
  if ((${#idx[@]} > 0)); then
    log_info "${repo}: ${#idx[@]} kept multi-arch image(s); protecting their platform images"
    local d
    for d in "${idx[@]}"; do
      aws_cli ecr batch-get-image --repository-name "${repo}" --image-ids "imageDigest=${d}" \
        --accepted-media-types application/vnd.oci.image.index.v1+json \
        application/vnd.docker.distribution.manifest.list.v2+json |
        jq -r '.images[]?.imageManifest | fromjson | .manifests[]?.digest' >>"${tmp}/children.txt"
    done
  fi
  jq --rawfile children "${tmp}/children.txt" '
    ($children | split("\n") | map(select(length > 0))) as $kids
    | map(if .action == "candidate" then
            (if (.digest | IN($kids[])) then .action = "keep" | .reason = "platform image of a kept multi-arch tag"
             else .action = "delete" end)
          else . end)' "${plan}" >"${plan}.new"
  mv -f -- "${plan}.new" "${plan}"
}

print_plan() {
  local repo="$1" plan="$2" rows
  rows=$(jq -r --argjson show_kept "${SHOW_KEPT}" "${JQ_DEFS}"'
    def mib: . / 1048576 * 10 | round / 10;
    # Kept images are shown only with --show-kept, or when a safety rule kept them.
    .[] | select(.action == "delete" or $show_kept or (.reason | startswith("newest ") | not))
    | [ (.action | ascii_upcase), .digest[0:19],
        (if (.tags | length) == 0 then "<untagged>" else (.tags | join(",")) end),
        (.pushed | utc), "\(.size | mib) MiB", .reason ] | @tsv' "${plan}")
  if [[ -n "${rows}" ]]; then
    printf 'ACTION\tDIGEST\tTAGS\tPUSHED_AT (UTC)\tSIZE\tREASON\n%s\n' "${rows}" |
      if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else cat; fi
  fi
  jq -r --arg repo "${repo}" '
    (map(select(.action == "delete"))) as $d
    | "\($repo): \($d | length) to delete (\(($d | map(.size) | add // 0) / 1048576 | round) MiB), \(map(select(.action == "keep")) | length) kept"' "${plan}"
}

DELETE_FAILURES=0

delete_images() {
  local repo="$1" plan="$2" tmp="$3"
  local -a ids=()
  local d
  mapfile -t ids < <(jq -r '.[] | select(.action == "delete") | "imageDigest=\(.digest)"' "${plan}")
  # batch-delete-image accepts at most 100 image IDs per call.
  local i
  for ((i = 0; i < ${#ids[@]}; i += 100)); do
    aws_cli ecr batch-delete-image --repository-name "${repo}" --image-ids "${ids[@]:i:100}" >"${tmp}/delete.json"
    while IFS= read -r d; do log_info "deleted ${repo}@${d}"; done < <(jq -r '.imageIds[]?.imageDigest' "${tmp}/delete.json" | sort -u)
    while IFS= read -r d; do
      log_error "failed ${repo}: ${d}"; DELETE_FAILURES=$((DELETE_FAILURES + 1))
    done < <(jq -r '.failures[]? | "\(.imageId.imageDigest // .imageId.imageTag): \(.failureCode) \(.failureReason)"' "${tmp}/delete.json")
  done
}

main() {
  parse_args "$@"
  check_aws_access
  local tmp repo plan to_delete=0 n
  make_tmpdir tmp

  for repo in "${REPOS[@]}"; do
    plan_repo "${repo}" "${tmp}"
    plan="${tmp}/plan-${repo//\//_}.json"
    printf '\n== %s ==\n' "${repo}"
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
    log_info "dry run: ${to_delete} image(s) would be deleted. Re-run with --apply to delete them."
    return 0
  fi
  confirm "Delete ${to_delete} image(s) from ${#REPOS[@]} repository(ies)?" || die "aborted by user" "${EXIT_ABORTED}"

  for repo in "${REPOS[@]}"; do
    plan="${tmp}/plan-${repo//\//_}.json"
    delete_images "${repo}" "${plan}" "${tmp}"
  done
  if ((DELETE_FAILURES > 0)); then
    die "${DELETE_FAILURES} image(s) could not be deleted"
  fi
  log_info "deleted ${to_delete} image(s)"
}

main "$@"
