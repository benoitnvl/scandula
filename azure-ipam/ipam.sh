#!/usr/bin/env bash
# Wrapper around Microsoft's Azure IPAM installer (github.com/Azure/ipam), pinned
# to one release. Runbook: azure-ipam/README.md. Why: docs/azure-ipam-plan.md.
#
#   ipam.sh fetch    clone the pinned release; verify its commit and the zip checksum
#   ipam.sh check    check pwsh, Az / Graph modules, bicep, and the Azure PowerShell context
#   ipam.sh apps     part 1, run by a tenant admin: the Entra ID app registrations
#   ipam.sh infra    part 2: the infrastructure. It costs money, so it's guarded.
#   ipam.sh update   zip-deploy the pinned release to an existing install
#
# Always installs *native* (zip deploy of the pinned ipam.zip). The default container
# install runs azureipam.azurecr.io/ipam:latest, which would ignore the pin.
#
# Written for bash 3.2 (macOS /bin/bash): no mapfile, no associative arrays.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WORK=${IPAM_WORK_DIR:-$HERE/.work}
UPSTREAM_URL=https://github.com/Azure/ipam.git
# Offer IDs (subscriptionPolicies.quotaId) of credit and trial subscriptions.
CREDIT_OFFER_RE='^(MSDN|FreeTrial|AzurePass|Sponsored|DreamSpark|Students|AzureForStudents)'

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '[*] %s\n' "$*"; }

# Non-interactive PowerShell one-liner, for queries only.
pwsh_q() { pwsh -NoLogo -NoProfile -NonInteractive -Command "$1"; }

# version_ge HAVE NEED: true if HAVE >= NEED (dotted numeric versions).
version_ge() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    n = split(a, x, "."); m = split(b, y, "."); k = (n > m ? n : m)
    for (i = 1; i <= k; i++) { if (x[i] + 0 > y[i] + 0) exit 0; if (x[i] + 0 < y[i] + 0) exit 1 }
    exit 0 }'
}

sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else sha256sum "$1" | awk '{print $1}'; fi
}

# Everything below ends up inside a PowerShell -Command string, in single quotes.
# Strict patterns here mean no value can break out of them.
validate() {
  local re
  re='^v[0-9]+\.[0-9]+\.[0-9]+$';        [[ $IPAM_VERSION =~ $re ]]     || die "IPAM_VERSION must look like v3.6.0"
  re='^[0-9a-f]{40}$';                   [[ $IPAM_COMMIT =~ $re ]]      || die "IPAM_COMMIT must be a full 40-character commit id"
  re='^[0-9a-f]{64}$';                   [[ $IPAM_ZIP_SHA256 =~ $re ]]  || die "IPAM_ZIP_SHA256 must be 64 lowercase hex characters"
  re='^[a-z0-9]+$';                      [[ $IPAM_LOCATION =~ $re ]]    || die "IPAM_LOCATION must be an Azure region name, e.g. eastasia"
  re='^[a-z0-9]{1,7}$';                  [[ $IPAM_NAME_PREFIX =~ $re ]] || die "IPAM_NAME_PREFIX must be 1-7 lowercase letters or digits"
  re='^[A-Za-z0-9][A-Za-z0-9-]{0,62}$'
  [[ $IPAM_UI_APP_NAME =~ $re && $IPAM_ENGINE_APP_NAME =~ $re ]] || die "app registration names may only use letters, digits and hyphens"
  re='^[A-Za-z0-9._()-]*$';              [[ $IPAM_MGMT_GROUP =~ $re ]]  || die "IPAM_MGMT_GROUP may only use letters, digits and . _ ( ) -"
  case $IPAM_DISABLE_UI in true|false) ;; *) die "IPAM_DISABLE_UI must be true or false" ;; esac
  case $WORK in *"'"*) die "IPAM_WORK_DIR must not contain a single quote" ;; esac
}

# check SCOPE: apps (needs Graph) | infra (needs bicep) | update | all
check() {
  local scope=$1 v
  command -v pwsh >/dev/null 2>&1 || die "pwsh (PowerShell 7.2 or later) is not installed"
  # shellcheck disable=SC2016 # PowerShell's $ variables, deliberately not expanded by bash
  v=$(pwsh_q '$PSVersionTable.PSVersion.ToString()') || die "pwsh failed to start"
  version_ge "$v" 7.2.0 || die "PowerShell $v is too old: 7.2.0 or later is needed"
  info "PowerShell $v"

  v=$(pwsh_q '(Get-Module -ListAvailable -Name Az | Sort-Object Version -Descending | Select-Object -First 1).Version.ToString()' 2>/dev/null || true)
  { [ -n "$v" ] && version_ge "$v" 8.0.0; } || die "Azure PowerShell (Az) 8.0.0 or later is needed (11.4.0+ recommended): Install-Module Az"
  info "Az $v"

  if [ "$scope" = apps ] || [ "$scope" = all ]; then
    v=$(pwsh_q '(Get-Module -ListAvailable -Name Microsoft.Graph.Authentication | Sort-Object Version -Descending | Select-Object -First 1).Version.ToString()' 2>/dev/null || true)
    { [ -n "$v" ] && version_ge "$v" 2.0.0; } || die "Microsoft Graph PowerShell 2.0.0 or later is needed for part 1: Install-Module Microsoft.Graph"
    info "Microsoft.Graph $v"
  fi

  if [ "$scope" = infra ] || [ "$scope" = all ]; then
    command -v bicep >/dev/null 2>&1 || die "the Bicep CLI (0.21.1 or later) is needed for part 2"
    v=$(bicep --version | grep -o -E '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    version_ge "$v" 0.21.1 || die "Bicep $v is too old: 0.21.1 or later is needed"
    info "Bicep $v"
  fi

  # shellcheck disable=SC2016 # PowerShell's $ variables, deliberately not expanded by bash
  v=$(pwsh_q '$c = Get-AzContext; if ($c) { "$($c.Subscription.Id) $($c.Tenant.Id)" }' 2>/dev/null || true)
  [ -n "$v" ] || die "no Azure PowerShell context: run Connect-AzAccount, then Set-AzContext -Subscription <id>"
  info "Azure PowerShell context: subscription ${v%% *}, tenant ${v##* }"
}

upstream_dir() { printf '%s/ipam-%s' "$WORK" "$IPAM_VERSION"; }
zip_path() { printf '%s/ipam-%s.zip' "$WORK" "$IPAM_VERSION"; }

fetch() {
  local dir zip head sum
  dir=$(upstream_dir); zip=$(zip_path)
  mkdir -p "$WORK"

  if [ ! -d "$dir" ]; then
    info "cloning Azure/ipam $IPAM_VERSION"
    git clone --quiet --depth 1 --branch "$IPAM_VERSION" "$UPSTREAM_URL" "$dir"
  fi
  head=$(git -C "$dir" rev-parse HEAD)
  [ "$head" = "$IPAM_COMMIT" ] || die "$dir is at $head, not the pinned $IPAM_COMMIT ($IPAM_VERSION). Either the tag moved or the checkout changed: investigate before deleting $dir to re-fetch."
  info "upstream $IPAM_VERSION verified at $IPAM_COMMIT"

  if [ ! -f "$zip" ]; then
    info "downloading ipam.zip for $IPAM_VERSION"
    curl -fsSL --retry 3 -o "$zip.part" "https://github.com/Azure/ipam/releases/download/$IPAM_VERSION/ipam.zip"
    mv "$zip.part" "$zip"
  fi
  sum=$(sha256 "$zip")
  [ "$sum" = "$IPAM_ZIP_SHA256" ] || die "ipam.zip has sha256 $sum, not the pinned $IPAM_ZIP_SHA256. Delete $zip and re-fetch; if it still differs, the release asset changed, so stop and investigate."
  info "ipam.zip verified (sha256 $sum)"
}

# Part 1: app registrations. Run by someone with Global Administrator and a
# role-assignment role at the management group the engine reads (tenant root by default).
apps() {
  local out dir cmd
  out=$WORK/main.parameters.json; dir=$(upstream_dir)
  [ ! -e "$out" ] || die "$out already exists. It holds an engine client secret from an earlier run: hand it over or delete it deliberately first."
  check apps
  fetch

  # -AppsOnly accepts only these switches: no -Location, -NamePrefix, -Tags or -ParameterFile.
  cmd="& ./deploy.ps1 -AppsOnly -UIAppName '$IPAM_UI_APP_NAME' -EngineAppName '$IPAM_ENGINE_APP_NAME'"
  [ -z "$IPAM_MGMT_GROUP" ] || cmd="$cmd -MgmtGroupId '$IPAM_MGMT_GROUP'"
  [ "$IPAM_DISABLE_UI" = false ] || cmd="$cmd -DisableUI"

  info "part 1: creating the app registrations"
  # deploy.ps1 writes main.parameters.json into the current directory. It runs under
  # umask 077 so the secret is created 600; mv keeps that mode, and the chmod is a backstop.
  (cd "$dir/deploy" && umask 077 && pwsh -NoLogo -NoProfile -Command "$cmd")
  [ -f "$dir/deploy/main.parameters.json" ] || die "deploy.ps1 finished but wrote no main.parameters.json"
  mv "$dir/deploy/main.parameters.json" "$out"
  chmod 600 "$out"
  info "wrote $out (mode 600). It contains the engine's client secret: hand it to whoever runs part 2 over a secure channel. Never commit it or paste it anywhere."
}

# Part 2: infrastructure, zip-deployed from the pinned release.
infra() {
  local param dir quota cmd
  param=${IPAM_PARAMETER_FILE:-$WORK/main.parameters.json}
  [ -f "$param" ] || die "no parameter file at $param. Part 1 (make ipam-apps) produces it."
  param=$(cd "$(dirname "$param")" && pwd)/$(basename "$param")
  case $param in *"'"*) die "the parameter file path must not contain a single quote" ;; esac
  [ "${IPAM_CONFIRM_COST:-}" = yes ] || die "part 2 runs a P1v3 App Service and Cosmos DB, about \$170-250/month (docs/azure-ipam-plan.md). Re-run with IPAM_CONFIRM_COST=yes to accept that."
  check infra

  quota=$(pwsh_q '(Get-AzSubscription -SubscriptionId (Get-AzContext).Subscription.Id).SubscriptionPolicies.QuotaId' 2>/dev/null || true)
  [ -n "$quota" ] || die "couldn't read the target subscription's offer (QuotaId)"
  if [[ $quota =~ $CREDIT_OFFER_RE ]]; then
    [ "${IPAM_ALLOW_CREDIT_SUBSCRIPTION:-}" = yes ] || die "the target subscription is a credit offer ($quota). If it has a spending limit, Azure IPAM would exhaust it within days, and then the whole subscription (tfstate included) gets disabled. Use a paid subscription, or set IPAM_ALLOW_CREDIT_SUBSCRIPTION=yes if you really mean it."
    printf 'warning: deploying to a credit subscription (%s) because IPAM_ALLOW_CREDIT_SUBSCRIPTION=yes\n' "$quota" >&2
  fi

  fetch
  dir=$(upstream_dir)
  cmd="& ./deploy.ps1 -Native -ZipFilePath '$(zip_path)' -ParameterFile '$param' -Location '$IPAM_LOCATION' -NamePrefix '$IPAM_NAME_PREFIX' -Tags @{ 'managed-by' = 'azure-ipam/ipam.sh'; repo = 'benoitnvl/scandula' }"
  [ "$IPAM_DISABLE_UI" = false ] || cmd="$cmd -DisableUI"

  info "part 2: deploying Azure IPAM $IPAM_VERSION to $IPAM_LOCATION (subscription offer $quota)"
  (cd "$dir/deploy" && pwsh -NoLogo -NoProfile -Command "$cmd")
}

# Upgrade: zip-deploy the pinned release. Without -ZipFilePath, update.ps1 would
# fetch releases/latest and bypass the pin.
update() {
  local re='^[A-Za-z0-9._()-]{1,90}$' dir cmd
  [[ ${IPAM_APP_NAME:-} =~ $re ]] || die "set IPAM_APP_NAME to the Azure IPAM App Service's name"
  [[ ${IPAM_RESOURCE_GROUP:-} =~ $re ]] || die "set IPAM_RESOURCE_GROUP to its resource group"
  check update
  fetch
  dir=$(upstream_dir)
  cmd="& ./update.ps1 -AppName '$IPAM_APP_NAME' -ResourceGroupName '$IPAM_RESOURCE_GROUP' -ZipFilePath '$(zip_path)'"
  info "zip-deploying Azure IPAM $IPAM_VERSION to $IPAM_APP_NAME"
  (cd "$dir/deploy" && pwsh -NoLogo -NoProfile -Command "$cmd")
}

usage() {
  sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

main() {
  # shellcheck source=settings.sh
  . "$HERE/settings.sh"
  validate
  case ${1:-} in
    fetch)  fetch ;;
    check)  check all ;;
    apps)   apps ;;
    infra)  infra ;;
    update) update ;;
    *)      usage; exit 2 ;;
  esac
}

main "$@"
