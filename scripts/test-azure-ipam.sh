#!/usr/bin/env bash
# Tests for azure-ipam/ipam.sh with stubbed pwsh, git, curl and bicep: no Azure, no
# network, no PowerShell needed. Each stub logs its call, and the tests assert on the
# exact commands and on every guard. `make ipam-test`; CI runs it too.
#
# What this can't prove: that Microsoft's deploy.ps1 accepts these commands. That's
# checked against its v3.6.0 parameter sets by reading them, and only a real run proves it.
#
# Written for bash 3.2 (macOS /bin/bash).
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=$REPO/azure-ipam/ipam.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
STUBS=$TMP/bin
LOG=$TMP/calls.log
OUT=$TMP/out.txt
WORK=$TMP/work
mkdir -p "$STUBS"

sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else sha256sum "$1" | awk '{print $1}'; fi
}

FAKE_COMMIT=1111111111111111111111111111111111111111
printf 'fake-zip\n' > "$TMP/fake.zip"
FAKE_SHA=$(sha256 "$TMP/fake.zip")

# --- stubs ------------------------------------------------------------------------
cat > "$STUBS/git" <<'EOF'
#!/usr/bin/env bash
echo "git $*" >> "$STUB_LOG"
if [ "$1" = clone ]; then
  for dest; do :; done
  mkdir -p "$dest/deploy"; : > "$dest/deploy/deploy.ps1"; : > "$dest/deploy/update.ps1"
elif [ "$1" = -C ] && [ "$3" = rev-parse ]; then
  echo "$STUB_COMMIT"
fi
EOF

cat > "$STUBS/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >> "$STUB_LOG"
out=""; prev=""
for a; do [ "$prev" = -o ] && out=$a; prev=$a; done
cp "$STUB_ZIP" "$out"
EOF

cat > "$STUBS/bicep" <<'EOF'
#!/usr/bin/env bash
echo "Bicep CLI version ${STUB_BICEP_VERSION:-0.30.3} (0000000)"
EOF

cat > "$STUBS/pwsh" <<'EOF'
#!/usr/bin/env bash
for cmd; do :; done   # the -Command script is the last argument
echo "pwsh $cmd" >> "$STUB_LOG"
case $cmd in
  *'$PSVersionTable'*)                 echo "${STUB_PWSH_VERSION:-7.4.1}" ;;
  *'-Name Az |'*)                      echo "${STUB_AZ_VERSION:-11.4.0}" ;;
  *'Microsoft.Graph.Authentication'*)  echo "${STUB_GRAPH_VERSION:-2.10.0}" ;;
  *'Get-AzContext; if'*)               echo "00000000-0000-0000-0000-000000000000 11111111-1111-1111-1111-111111111111" ;;
  *'QuotaId'*)                         echo "${STUB_QUOTA:-EnterpriseAgreement_2014-09-01}" ;;
  *'./deploy.ps1 -AppsOnly'*)          printf '{"engineSecret":"STUB-SECRET-VALUE"}\n' > main.parameters.json ;;
  *'./deploy.ps1'*)                    echo "deployed" ;;
  *'./update.ps1'*)                    echo "updated" ;;
esac
EOF
chmod +x "$STUBS"/*

# --- harness ----------------------------------------------------------------------
pass=0; fail=0; got=0

# run [VAR=value ...] -- SUBCOMMAND: runs ipam.sh against the stubs; sets $got.
run() {
  local envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  : > "$LOG"
  set +e
  env PATH="$STUBS:$PATH" STUB_LOG="$LOG" STUB_ZIP="$TMP/fake.zip" STUB_COMMIT="$FAKE_COMMIT" \
    IPAM_WORK_DIR="$WORK" IPAM_COMMIT="$FAKE_COMMIT" IPAM_ZIP_SHA256="$FAKE_SHA" \
    ${envs[@]+"${envs[@]}"} bash "$SCRIPT" "$@" > "$OUT" 2>&1
  got=$?
  set -e
}

ok() {
  local desc=$1; shift
  if "$@"; then pass=$((pass + 1)); printf '  ok    %s\n' "$desc"
  else fail=$((fail + 1)); printf '  FAIL  %s\n' "$desc"; sed 's/^/        | /' "$OUT"; fi
}
has()    { grep -q -F -- "$2" "$1"; }
lacks()  { ! grep -q -F -- "$2" "$1"; }
exited() { [ "$got" = "$1" ]; }
failed() { [ "$got" != 0 ]; }
empty()  { [ ! -s "$1" ]; }
fresh()  { rm -rf "$WORK"; mkdir -p "$WORK"; }

# --- fetch ------------------------------------------------------------------------
echo "fetch"
fresh; run -- fetch
ok "exits 0"                           exited 0
ok "clones the pinned tag, shallow"    has "$LOG" "git clone --quiet --depth 1 --branch v3.6.0 https://github.com/Azure/ipam.git"
ok "downloads the pinned release zip"  has "$LOG" "releases/download/v3.6.0/ipam.zip"
ok "reports the verified commit"       has "$OUT" "verified at $FAKE_COMMIT"

fresh; run STUB_COMMIT=2222222222222222222222222222222222222222 -- fetch
ok "refuses a clone at the wrong commit" failed
ok "  and says so"                       has "$OUT" "not the pinned"

fresh; run IPAM_ZIP_SHA256=0000000000000000000000000000000000000000000000000000000000000000 -- fetch
ok "refuses a zip with the wrong checksum" failed
ok "  and says so"                          has "$OUT" "not the pinned 0000"

# --- validation -------------------------------------------------------------------
echo "validation"
fresh; run IPAM_NAME_PREFIX=toolong12 -- fetch
ok "refuses a name prefix over 7 characters" failed
ok "  before calling anything"               empty "$LOG"

fresh; run "IPAM_LOCATION=eastasia'; Remove-Item -Recurse /" -- fetch
ok "refuses a value that could break out of the PowerShell quotes" failed
ok "  before calling anything"                                     empty "$LOG"

fresh; run IPAM_DISABLE_UI=maybe -- fetch
ok "refuses IPAM_DISABLE_UI other than true/false" failed

# Each name on its own: one good name must not let the other through.
fresh; run "IPAM_UI_APP_NAME=ui'; Remove-Item /" -- fetch
ok "refuses a bad UI app name"     failed
ok "  before calling anything"     empty "$LOG"

fresh; run "IPAM_ENGINE_APP_NAME=engine name" -- fetch
ok "refuses a bad engine app name" failed
ok "  before calling anything"     empty "$LOG"

# --- check ------------------------------------------------------------------------
echo "check"
fresh; run -- check
ok "passes with current tools"          exited 0
ok "  reports bicep"                    has "$OUT" "Bicep 0.30.3"
fresh; run STUB_PWSH_VERSION=7.1.0 -- check
ok "refuses PowerShell older than 7.2"  failed
fresh; run STUB_AZ_VERSION=7.5.0 -- check
ok "refuses Az older than 8.0"          failed
fresh; run STUB_BICEP_VERSION=0.20.4 -- check
ok "refuses bicep older than 0.21.1"    failed

# --- apps (part 1) ----------------------------------------------------------------
echo "apps (part 1)"
fresh; run -- apps
ok "exits 0"                                 exited 0
ok "runs deploy.ps1 -AppsOnly with the app names" \
   has "$LOG" "& ./deploy.ps1 -AppsOnly -UIAppName 'scandula-ipam-ui' -EngineAppName 'scandula-ipam-engine'"
ok "  without switches -AppsOnly doesn't accept" \
   eval "lacks '$LOG' ' -Location ' && lacks '$LOG' ' -NamePrefix ' && lacks '$LOG' ' -Tags ' && lacks '$LOG' ' -ParameterFile '"
ok "  without -MgmtGroupId by default (tenant root)" lacks "$LOG" "-MgmtGroupId"
ok "moves main.parameters.json into the work dir"    [ -f "$WORK/main.parameters.json" ]
ok "  out of the upstream checkout"                  [ ! -e "$WORK/ipam-v3.6.0/deploy/main.parameters.json" ]
ok "  with mode 600"                                 eval "ls -l '$WORK/main.parameters.json' | grep -q '^-rw-------'"
ok "never prints the secret"                         lacks "$OUT" "STUB-SECRET-VALUE"

run -- apps
ok "refuses to overwrite an existing parameter file" failed
ok "  without running deploy.ps1 again"              lacks "$LOG" "deploy.ps1"

fresh; run IPAM_MGMT_GROUP=mg-aberdeen IPAM_DISABLE_UI=true -- apps
ok "passes -MgmtGroupId when set"  has "$LOG" "-MgmtGroupId 'mg-aberdeen'"
ok "passes -DisableUI when set"    has "$LOG" "-DisableUI"

# --- infra (part 2) ---------------------------------------------------------------
echo "infra (part 2)"
fresh; run IPAM_CONFIRM_COST=yes -- infra
ok "refuses without a parameter file" failed
ok "  and says where it comes from"   has "$OUT" "make ipam-apps"

fresh; printf '{}\n' > "$WORK/main.parameters.json"
run -- infra
ok "refuses without IPAM_CONFIRM_COST=yes" failed
ok "  naming the cost"                     has "$OUT" "170-250/month"
ok "  without deploying"                   lacks "$LOG" "deploy.ps1"

run IPAM_CONFIRM_COST=yes STUB_QUOTA=MSDN_2014-09-01 -- infra
ok "refuses a Visual Studio (MSDN) credit subscription" failed
ok "  naming the offer"                                  has "$OUT" "credit offer (MSDN_2014-09-01)"
ok "  without deploying"                                 lacks "$LOG" "deploy.ps1"

run IPAM_CONFIRM_COST=yes STUB_QUOTA=MSDN_2014-09-01 IPAM_ALLOW_CREDIT_SUBSCRIPTION=yes -- infra
ok "deploys to a credit subscription only with the explicit override" exited 0
ok "  and warns"                                                       has "$OUT" "warning: deploying to a credit subscription"

run IPAM_CONFIRM_COST=yes -- infra
ok "deploys on a paid subscription with the cost confirmed" exited 0
ok "  natively, from the pinned zip, with the parameter file and settings" \
   has "$LOG" "& ./deploy.ps1 -Native -ZipFilePath '$WORK/ipam-v3.6.0.zip' -ParameterFile '$WORK/main.parameters.json' -Location 'eastasia' -NamePrefix 'scipam' -Tags @{ 'managed-by' = 'azure-ipam/ipam.sh'; repo = 'benoitnvl/scandula' }"
ok "  never as -AppsOnly"   lacks "$LOG" "-AppsOnly"
ok "  never the container"  lacks "$LOG" "-PrivateACR"

# --- update -----------------------------------------------------------------------
echo "update"
fresh; run -- update
ok "refuses without IPAM_APP_NAME" failed
fresh; run IPAM_APP_NAME=scipam-app IPAM_RESOURCE_GROUP=scipam-rg -- update
ok "exits 0"  exited 0
ok "zip-deploys the pinned zip, never releases/latest" \
   has "$LOG" "& ./update.ps1 -AppName 'scipam-app' -ResourceGroupName 'scipam-rg' -ZipFilePath '$WORK/ipam-v3.6.0.zip'"

echo
printf 'pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
