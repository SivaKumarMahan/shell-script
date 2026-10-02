#!/usr/bin/env bash
# End-to-end test of ssm-params.sh against a real LocalStack SSM.
#
#   docker run -d --name localstack -p 127.0.0.1:4566:4566 localstack/localstack:4.4.0
#   AWS_ENDPOINT_URL=http://localhost:4566 tests/integration/ssm-localstack.sh
#
# Safety: refuses to run unless AWS_ENDPOINT_URL points at localhost / localstack,
# so it can never write test parameters into a real account.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SSM="${HERE}/../../ssm-params.sh"

: "${AWS_ENDPOINT_URL:?set AWS_ENDPOINT_URL, for example http://localhost:4566}"
if [[ ! "${AWS_ENDPOINT_URL}" =~ ^https?://(localhost|127\.0\.0\.1|localstack)(:[0-9]+)?/?$ ]]; then
  echo "refusing to run: AWS_ENDPOINT_URL (${AWS_ENDPOINT_URL}) is not a local endpoint" >&2
  exit 2
fi
# LocalStack accepts any credentials; never use a real profile here.
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_REGION="${AWS_REGION:-us-east-1}"
unset AWS_PROFILE AWS_SESSION_TOKEN
export AWS_PAGER=""

base="/ops-toolkit-it/$$"
work=$(mktemp -d)
cleanup() {
  local names
  names=$(aws ssm get-parameters-by-path --path "${base}" --recursive --query 'Parameters[].Name' --output text 2>/dev/null || true)
  if [[ -n "${names}" ]]; then
    # shellcheck disable=SC2086  # word splitting of the name list is intended
    aws ssm delete-parameters --names ${names} >/dev/null || true
  fi
  rm -rf -- "${work}"
}
trap cleanup EXIT

passed=0
step() { printf '\n== %s\n' "$*"; }
ok() { passed=$((passed + 1)); printf 'ok: %s\n' "$*"; }
die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

step "seed ${base}/dev"
aws ssm put-parameter --name "${base}/dev/db/host" --type String --value db.dev.internal >/dev/null
aws ssm put-parameter --name "${base}/dev/db/password" --type SecureString --value 'it-FAKE-secret' >/dev/null
aws ssm put-parameter --name "${base}/dev/app/hosts" --type StringList --value 'a,b' >/dev/null
# A URL value: AWS CLI v1 fetched URLs given as --value. ssm-params.sh uses
# --cli-input-json, so the value must come through unchanged.
aws ssm put-parameter --name "${base}/dev/app/url" --type String --value 'https://example.com/health' >/dev/null

step "export"
out=$("${SSM}" export --path "${base}/dev" --file "${work}/dev.json" 2>&1)
[[ "$(stat -c %a "${work}/dev.json")" == 600 ]] || die "export file is not mode 600"
[[ "$(jq '.parameters | length' "${work}/dev.json")" == 4 ]] || die "expected 4 exported parameters"
[[ "$(jq -r '.parameters[] | select(.name == "db/password") | .value' "${work}/dev.json")" == it-FAKE-secret ]] ||
  die "SecureString was not decrypted in the export"
[[ "${out}" != *FAKE-secret* ]] || die "export printed a secret"
ok "export wrote 4 parameters, mode 600, no secrets on screen"

step "import --dry-run"
out=$("${SSM}" import --path "${base}/stg" --file "${work}/dev.json" --dry-run 2>&1)
[[ "${out}" == *"4 to create"* ]] || die "dry run plan wrong: ${out}"
[[ -z "$(aws ssm get-parameters-by-path --path "${base}/stg" --recursive --query 'Parameters[].Name' --output text)" ]] ||
  die "dry run created parameters"
ok "dry run planned 4 creates and wrote nothing"

step "import without --yes and without a terminal must refuse"
set +e
"${SSM}" import --path "${base}/stg" --file "${work}/dev.json" </dev/null >/dev/null 2>&1
rc=$?
set -e
[[ "${rc}" == 4 ]] || die "expected exit 4, got ${rc}"
ok "refused with exit 4"

step "import --yes"
"${SSM}" import --path "${base}/stg" --file "${work}/dev.json" --yes >/dev/null 2>&1
[[ "$(aws ssm get-parameter --name "${base}/stg/db/password" --query Parameter.Type --output text)" == SecureString ]] ||
  die "SecureString type not kept"
[[ "$(aws ssm get-parameter --name "${base}/stg/app/url" --query Parameter.Value --output text)" == https://example.com/health ]] ||
  die "URL value was changed"
ok "import created 4 parameters with the right types and values"

step "diff (identical)"
"${SSM}" diff --left "${base}/dev" --right "${base}/stg" >/dev/null 2>&1 || die "expected no differences"
ok "diff exit 0"

step "diff (changed)"
aws ssm put-parameter --name "${base}/stg/db/password" --type SecureString --value 'it-FAKE-other' --overwrite >/dev/null
aws ssm put-parameter --name "${base}/stg/extra" --type String --value x >/dev/null
set +e
out=$("${SSM}" diff --left "${base}/dev" --right "${base}/stg" 2>/dev/null)
rc=$?
set -e
printf '%s\n' "${out}"
[[ "${rc}" == 5 ]] || die "expected exit 5, got ${rc}"
[[ "${out}" == *"db/password (SecureString): values differ"* ]] || die "secure diff line missing"
[[ "${out}" == *"ONLY_RIGHT  extra (String)"* ]] || die "only-right line missing"
[[ "${out}" != *FAKE* ]] || die "diff printed a secret without --show-secrets"
out=$("${SSM}" diff --left "${base}/dev" --right "${base}/stg" --show-secrets 2>/dev/null || true)
[[ "${out}" == *'"it-FAKE-secret" -> "it-FAKE-other"'* ]] || die "--show-secrets did not show values"
ok "diff found 2 differences, masked secrets, --show-secrets revealed them"

step "import --overwrite brings stg back in line"
"${SSM}" import --path "${base}/stg" --file "${work}/dev.json" --overwrite --yes >/dev/null 2>&1
set +e
"${SSM}" diff --left "${base}/dev" --right "${base}/stg" >/dev/null 2>&1
rc=$?
set -e
[[ "${rc}" == 5 ]] || die "expected only 'extra' to differ (exit 5), got ${rc}"
[[ "$(aws ssm get-parameter --name "${base}/stg/db/password" --with-decryption --query Parameter.Value --output text)" == it-FAKE-secret ]] ||
  die "overwrite did not restore the value"
ok "overwrite restored the changed value (extra parameter is left alone, as designed)"

printf '\nAll %s integration checks passed against %s\n' "${passed}" "${AWS_ENDPOINT_URL}"
