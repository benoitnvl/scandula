#!/usr/bin/env bash
# Tests for azure-ipam/ci.sh, the glue .github/workflows/azure-ipam-deploy.yaml runs,
# against a stub terraform: no Azure, no GitHub. `make ipam-test`; CI runs it too.
#
# What this can't prove: that GitHub's OIDC token gets through to Azure. Only a real
# workflow run proves that.
#
# Written for bash 3.2 (macOS /bin/bash).
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
CI="$REPO/azure-ipam/ci.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
LOG="$T/tf.log" OUT="$T/out" ERR="$T/err"

# --- stub terraform -----------------------------------------------------------------
cat > "$T/terraform" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
for last; do :; done
case " $* " in
  *" init "*) echo "stub: Terraform has been successfully initialized!" ;;
  *" output -json "*) if [ -n "${STUB_OUTPUTS:-}" ]; then printf '%s\n' "$STUB_OUTPUTS"; else echo '{}'; fi ;;
  *" show -json "*) if [ -n "${STUB_SHOW_FAIL:-}" ]; then echo "stub: no plan" >&2; exit 1; fi; cat "$last" ;;
esac
EOF
chmod +x "$T/terraform"

# --- harness ------------------------------------------------------------------------
pass=0 fail=0 got=0

# run [VAR=value ...] -- ARGS...: ci.sh in an empty environment plus these variables.
run() {
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  : > "$LOG"
  env -i PATH="$PATH" HOME="$HOME" TF="$T/terraform" STUB_LOG="$LOG" ${envs[@]+"${envs[@]}"} \
    bash "$CI" "$@" > "$OUT" 2> "$ERR"
  got=$?
}

ok() {
  local name=$1; shift
  if "$@"; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL  $name"
    sed 's/^/        out: /' "$OUT"; sed 's/^/        err: /' "$ERR"
  fi
}
has() { grep -qF -- "$2" "$1"; }
lacks() { ! grep -qF -- "$2" "$1"; }
exited() { [ "$got" = "$1" ]; }
failed() { [ "$got" != 0 ]; }
nlines() { [ "$(grep -c '' "$OUT")" = "$1" ]; }
only_tfvars() { ! grep -qvE '^TF_VAR_[a-z_]+=' "$OUT"; }
empty() { [ ! -s "$1" ]; }
has_all() { local f=$1 s; shift; for s; do grep -qF -- "$s" "$f" || return 1; done; }
is_sha() { [[ $1 =~ ^[0-9a-f]{64}$ ]]; }
same() { [ -n "$1" ] && [ "$1" = "$2" ]; }
differ() { [ -n "$1" ] && [ -n "$2" ] && [ "$1" != "$2" ]; }

OWNERS='["0e0e0e0e-0000-0000-0000-000000000001"]'
STATE=(TFSTATE_RESOURCE_GROUP=rg-state TFSTATE_STORAGE_ACCOUNT=ststate TFSTATE_CONTAINER_PREFIX=tfstate-azure-ipam)

# --- tfvars entra -------------------------------------------------------------------------
echo "tfvars entra"
run IPAM_PLATFORM_OWNER_OBJECT_IDS="$OWNERS" -- tfvars entra
ok "exits 0"                                   exited 0
ok "passes the owners as a JSON list"          has "$OUT" 'TF_VAR_platform_owner_object_ids=["0e0e0e0e-0000-0000-0000-000000000001"]'
ok "  and nothing it wasn't given"             nlines 1

run IPAM_PLATFORM_OWNER_OBJECT_IDS="$OWNERS" IPAM_UI_ENABLED=false \
    IPAM_READER_MANAGEMENT_GROUP_ID=/providers/Microsoft.Management/managementGroups/mg-lz -- tfvars entra
ok "passes ui_enabled"                         has "$OUT" "TF_VAR_ui_enabled=false"
ok "passes reader_management_group_id"         has "$OUT" "TF_VAR_reader_management_group_id=/providers/Microsoft.Management/managementGroups/mg-lz"

run -- tfvars entra
ok "refuses no owners"                         failed
ok "  printing nothing for GITHUB_ENV"         empty "$OUT"

run IPAM_PLATFORM_OWNER_OBJECT_IDS=0e0e0e0e-0000-0000-0000-000000000001 -- tfvars entra
ok "refuses owners that aren't a JSON list"    failed

run IPAM_PLATFORM_OWNER_OBJECT_IDS='[]' -- tfvars entra
ok "refuses an empty owner list"               failed

run IPAM_PLATFORM_OWNER_OBJECT_IDS="$OWNERS" IPAM_UI_ENABLED=yes -- tfvars entra
ok "refuses ui_enabled other than true/false"  failed

run IPAM_PLATFORM_OWNER_OBJECT_IDS="$OWNERS" "IPAM_READER_MANAGEMENT_GROUP_ID=$(printf 'mg-lz\nTF_VAR_ipam_enabled=true')" -- tfvars entra
ok "refuses a value with a line break"         failed
ok "  so it can't smuggle in a variable"       lacks "$OUT" "TF_VAR_ipam_enabled"

# --- tfvars platform --------------------------------------------------------------------
echo "tfvars platform"
run -- tfvars platform
ok "exits 0"                                   exited 0
ok "keeps the cost guard off when unset"       has "$OUT" "TF_VAR_ipam_enabled=false"
ok "  and sets nothing else"                   nlines 1

run IPAM_ENABLED=true IPAM_NAME_PREFIX=scipam IPAM_LOCATION=southeastasia -- tfvars platform
ok "passes ipam_enabled = true"                has "$OUT" "TF_VAR_ipam_enabled=true"
ok "passes name_prefix and location"           has_all "$OUT" TF_VAR_name_prefix=scipam TF_VAR_location=southeastasia

run IPAM_ENABLED=TRUE -- tfvars platform
ok "refuses ipam_enabled other than true/false" failed

run IPAM_ENABLED=true IPAM_ALLOW_CREDIT_SUBSCRIPTION=true -- tfvars platform
ok "never allows a credit subscription"        lacks "$OUT" "allow_credit_subscription"

run -- tfvars prod
ok "refuses an unknown PART"                   failed

# --- init --------------------------------------------------------------------------------
echo "init"
run "${STATE[@]}" -- init platform
ok "exits 0"                                   exited 0
ok "inits part 2's root"                       has "$LOG" "-chdir=$REPO/azure-ipam/platform init -input=false -no-color"
ok "  against part 2's own container"          has_all "$LOG" "resource_group_name=rg-state" "storage_account_name=ststate" "container_name=tfstate-azure-ipam-platform"
ok "  under its own key"                       has "$LOG" "key=azure-ipam-platform.tfstate"
ok "  with Entra ID auth over OIDC"            has_all "$LOG" "use_azuread_auth=true" "use_oidc=true"
ok "  in ARM_SUBSCRIPTION_ID's subscription by default" lacks "$LOG" "subscription_id="

run "${STATE[@]}" TFSTATE_SUBSCRIPTION_ID=ee9dfbf0-0000-0000-0000-000000000000 -- init platform
ok "  or in TFSTATE_SUBSCRIPTION_ID's"         has "$LOG" "subscription_id=ee9dfbf0-0000-0000-0000-000000000000"

# One container per part, so neither identity needs write access to the other's state.
run "${STATE[@]}" -- init entra
ok "part 1 uses its own container"             has "$LOG" "container_name=tfstate-azure-ipam-entra"
ok "  not part 2's"                            lacks "$LOG" "container_name=tfstate-azure-ipam-platform"

run TFSTATE_RESOURCE_GROUP=rg-state TFSTATE_STORAGE_ACCOUNT=ststate -- init entra
ok "refuses a missing state variable"          failed
ok "  before calling terraform"                empty "$LOG"
# set -u alone would also stop it, with bash's "unbound variable": pin the message that
# says what to set.
ok "  naming the repository variable to set"   has "$ERR" "TFSTATE_CONTAINER_PREFIX is not set (a GitHub repository variable)"

# --- entra-outputs ------------------------------------------------------------------------
echo "entra-outputs"
FULL='{"engine_client_id":{"value":"eeeeeeee-0000-0000-0000-00000000e001"},"engine_application_id":{"value":"/applications/aaaaaaaa-0000-0000-0000-00000000e001"},"ui_client_id":{"value":"bbbbbbbb-0000-0000-0000-00000000b001"},"ui_application_id":{"value":"/applications/aaaaaaaa-0000-0000-0000-00000000b001"},"tenant_id":{"value":"11111111-1111-1111-1111-111111111111"}}'
run "${STATE[@]}" STUB_OUTPUTS="$FULL" -- entra-outputs
ok "exits 0"                                   exited 0
ok "reads part 1's state, not part 2's"        has_all "$LOG" "-chdir=$REPO/azure-ipam/entra init" "container_name=tfstate-azure-ipam-entra" "key=azure-ipam-entra.tfstate" "-chdir=$REPO/azure-ipam/entra output -json"
ok "passes the four ids part 2 needs"          has_all "$OUT" TF_VAR_engine_client_id=eeeeeeee-0000-0000-0000-00000000e001 \
  TF_VAR_engine_application_id=/applications/aaaaaaaa-0000-0000-0000-00000000e001 \
  TF_VAR_ui_client_id=bbbbbbbb-0000-0000-0000-00000000b001 \
  TF_VAR_ui_application_id=/applications/aaaaaaaa-0000-0000-0000-00000000b001
ok "  and only TF_VAR lines (init's output goes to stderr)" eval 'only_tfvars && nlines 4'

run "${STATE[@]}" STUB_OUTPUTS='{"engine_client_id":{"value":"eeeeeeee-0000-0000-0000-00000000e001"},"engine_application_id":{"value":"/applications/aaaaaaaa-0000-0000-0000-00000000e001"},"ui_client_id":{"value":null},"ui_application_id":{"value":null}}' -- entra-outputs
ok "API only: exits 0"                         exited 0
ok "  with just the two engine ids"            nlines 2
ok "  and no ui ids"                           lacks "$OUT" TF_VAR_ui_

run "${STATE[@]}" STUB_OUTPUTS='{}' -- entra-outputs
ok "refuses when part 1 isn't applied yet"     failed
ok "  saying so"                               has "$ERR" "apply part 1 (entra) first"

# --- digest --------------------------------------------------------------------------------
echo "digest"
printf '%s' '{"format_version":"1.2","timestamp":"2026-09-11T10:00:00Z","resource_changes":[{"address":"a","change":{"actions":["create"],"after":{"x":1,"y":2}}}],"output_changes":{"u":{"after":"v"}}}' > "$T/p1.json"
printf '%s' '{"output_changes":{"u":{"after":"v"}},"resource_changes":[{"change":{"after":{"y":2,"x":1},"actions":["create"]},"address":"a"}],"timestamp":"2026-09-11T10:05:00Z","format_version":"1.2"}' > "$T/p2.json"
printf '%s' '{"format_version":"1.2","timestamp":"2026-09-11T10:00:00Z","resource_changes":[{"address":"a","change":{"actions":["create"],"after":{"x":3,"y":2}}}],"output_changes":{"u":{"after":"v"}}}' > "$T/p3.json"
printf '%s' '{"format_version":"1.2","timestamp":"2026-09-11T10:00:00Z","resource_changes":[{"address":"a","change":{"actions":["create"],"after":{"x":1,"y":2}}}],"output_changes":{"u":{"after":"w"}}}' > "$T/p4.json"

run -- digest platform "$T/p1.json"; d1=$(cat "$OUT")
ok "exits 0"                                   exited 0
ok "is a SHA-256"                              is_sha "$d1"
run -- digest platform "$T/p2.json"; d2=$(cat "$OUT")
ok "ignores key order and the timestamp"       same "$d1" "$d2"
run -- digest platform "$T/p3.json"; d3=$(cat "$OUT")
ok "changes when a resource change does"       differ "$d1" "$d3"
run -- digest platform "$T/p4.json"; d4=$(cat "$OUT")
ok "changes when an output change does"        differ "$d1" "$d4"

run STUB_SHOW_FAIL=1 -- digest platform "$T/p1.json"
ok "fails when terraform show fails"           failed
ok "  printing no digest"                      empty "$OUT"

# --- usage ------------------------------------------------------------------------------------
echo "usage"
run -- apply entra
ok "refuses an unknown command"                failed
run -- digest platform
ok "refuses a missing argument"                failed

# The tests run it through bash; the workflow runs azure-ipam/ci.sh directly.
echo "packaging"
ok "ci.sh is executable"                       test -x "$CI"

echo
echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
