#!/usr/bin/env bash
# Glue for .github/workflows/azure-ipam-deploy.yaml. Azure IPAM is planned and applied
# only there, never from a workstation (azure-ipam/README.md). This runs in GitHub
# Actions; scripts/test-azure-ipam-ci.sh tests it against a stub terraform.
#
#   ci.sh tfvars PART        GitHub variables (IPAM_*) -> TF_VAR_* lines for $GITHUB_ENV
#   ci.sh init PART          terraform init against the state backend, over OIDC
#   ci.sh entra-outputs      part 1's outputs -> TF_VAR_* lines for part 2
#   ci.sh digest PART PLAN   a digest of a saved plan's changes. The apply job re-plans and
#                            refuses unless its digest matches the plan that was reviewed.
#
# PART is entra (part 1) or platform (part 2). Written for bash 3.2 as well, because
# macOS runs the tests.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
TF=${TF:-terraform}

die() { echo "ci.sh: $*" >&2; exit 1; }

root_of() {
  case ${1:-} in
    entra | platform) printf '%s/azure-ipam/%s' "$REPO" "$1" ;;
    *) die "PART must be entra or platform, not '${1:-}'" ;;
  esac
}

# One NAME=value line for $GITHUB_ENV. A line break in a value could smuggle in
# another variable, so refuse it.
emit() {
  case $2 in *$'\n'* | *$'\r'*) die "${1#TF_VAR_} contains a line break" ;; esac
  printf '%s=%s\n' "$1" "$2"
}

emit_bool() {
  case $2 in
    true | false) emit "$1" "$2" ;;
    *) die "${1#TF_VAR_} must be true or false, not '$2'" ;;
  esac
}

tfvars() {
  root_of "$1" > /dev/null
  case $1 in
    entra)
      [ -n "${IPAM_PLATFORM_OWNER_OBJECT_IDS:-}" ] ||
        die "IPAM_PLATFORM_OWNER_OBJECT_IDS is not set: the object id(s) of part 2's identity, as a JSON list"
      printf '%s' "$IPAM_PLATFORM_OWNER_OBJECT_IDS" | jq -e 'type == "array" and length > 0 and all(.[]; type == "string")' > /dev/null 2>&1 ||
        die "IPAM_PLATFORM_OWNER_OBJECT_IDS must be a JSON list of object ids, e.g. [\"<object id>\"]"
      emit TF_VAR_platform_owner_object_ids "$(printf '%s' "$IPAM_PLATFORM_OWNER_OBJECT_IDS" | jq -c .)"
      if [ -n "${IPAM_UI_ENABLED:-}" ]; then emit_bool TF_VAR_ui_enabled "$IPAM_UI_ENABLED"; fi
      if [ -n "${IPAM_READER_MANAGEMENT_GROUP_ID:-}" ]; then emit TF_VAR_reader_management_group_id "$IPAM_READER_MANAGEMENT_GROUP_ID"; fi
      if [ -n "${IPAM_ENGINE_APP_NAME:-}" ]; then emit TF_VAR_engine_app_name "$IPAM_ENGINE_APP_NAME"; fi
      if [ -n "${IPAM_UI_APP_NAME:-}" ]; then emit TF_VAR_ui_app_name "$IPAM_UI_APP_NAME"; fi
      ;;
    platform)
      # The cost guard: off unless the variable says true. Nothing here ever sets
      # allow_credit_subscription, so CI always refuses a credit subscription.
      emit_bool TF_VAR_ipam_enabled "${IPAM_ENABLED:-false}"
      if [ -n "${IPAM_NAME_PREFIX:-}" ]; then emit TF_VAR_name_prefix "$IPAM_NAME_PREFIX"; fi
      if [ -n "${IPAM_LOCATION:-}" ]; then emit TF_VAR_location "$IPAM_LOCATION"; fi
      ;;
  esac
}

# Client, tenant and subscription come from ARM_CLIENT_ID / ARM_TENANT_ID /
# ARM_SUBSCRIPTION_ID, and the token from GitHub (ARM_USE_OIDC), set by the workflow.
# The state account can live in another subscription than the one being deployed to
# (today it's the Visual Studio one): TFSTATE_SUBSCRIPTION_ID says which.
# Each part has its own container, <prefix>-entra and <prefix>-platform, so each CI
# identity can be given write access to its own state only. Part 2's state holds the
# engine secret, and the entra identity must not be able to read it.
init() {
  local root v sub=()
  root=$(root_of "$1")
  for v in TFSTATE_RESOURCE_GROUP TFSTATE_STORAGE_ACCOUNT TFSTATE_CONTAINER_PREFIX; do
    [ -n "${!v:-}" ] || die "$v is not set (a GitHub repository variable)"
  done
  if [ -n "${TFSTATE_SUBSCRIPTION_ID:-}" ]; then sub=(-backend-config="subscription_id=$TFSTATE_SUBSCRIPTION_ID"); fi
  "$TF" -chdir="$root" init -input=false -no-color \
    -backend-config="resource_group_name=$TFSTATE_RESOURCE_GROUP" \
    -backend-config="storage_account_name=$TFSTATE_STORAGE_ACCOUNT" \
    -backend-config="container_name=$TFSTATE_CONTAINER_PREFIX-$1" \
    -backend-config="key=azure-ipam-$1.tfstate" \
    -backend-config="use_azuread_auth=true" \
    -backend-config="use_oidc=true" \
    ${sub[@]+"${sub[@]}"}
}

# Part 2 reads part 1's outputs straight from part 1's state, which holds nothing
# secret. That replaces copying ids between the two by hand.
entra_outputs() {
  local root out k v
  root=$(root_of entra)
  init entra >&2
  out=$("$TF" -chdir="$root" output -json) || die "can't read part 1's outputs"
  for k in engine_client_id engine_application_id; do
    v=$(printf '%s' "$out" | jq -r --arg k "$k" '.[$k].value // empty')
    [ -n "$v" ] || die "part 1 has no $k output yet: apply part 1 (entra) first"
    emit "TF_VAR_$k" "$v"
  done
  for k in ui_client_id ui_application_id; do
    v=$(printf '%s' "$out" | jq -r --arg k "$k" '.[$k].value // empty')
    if [ -n "$v" ]; then emit "TF_VAR_$k" "$v"; fi
  done
}

sha256() {
  if command -v sha256sum > /dev/null; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi
}

# Only what the plan would change (resource and output changes, keys sorted), not
# metadata like its timestamp. Sensitive values count too; only the digest leaves.
digest() {
  local root json
  root=$(root_of "$1")
  json=$("$TF" -chdir="$root" show -json "$2") || die "terraform show -json $2 failed"
  printf '%s' "$json" | jq -cS '{resource_changes, output_changes}' | sha256
}

cmd=${1:-}
[ $# -eq 0 ] || shift
case $cmd in
  tfvars) [ $# -eq 1 ] || die "usage: ci.sh tfvars PART"; tfvars "$1" ;;
  init) [ $# -eq 1 ] || die "usage: ci.sh init PART"; init "$1" ;;
  entra-outputs) [ $# -eq 0 ] || die "usage: ci.sh entra-outputs"; entra_outputs ;;
  digest) [ $# -eq 2 ] || die "usage: ci.sh digest PART PLANFILE"; digest "$1" "$2" ;;
  *) die "usage: ci.sh tfvars PART | init PART | entra-outputs | digest PART PLANFILE" ;;
esac
