# Azure IPAM, as Terraform, deployed by GitHub Actions

Microsoft's [Azure IPAM](https://github.com/Azure/ipam) (`Azure/ipam`), deployed by two
Terraform roots instead of its PowerShell installer (`deploy.ps1` + Bicep). They reproduce what
`deploy.ps1` creates at release **v3.6.0**, with the differences listed below. **Both are applied
only by the `azure-ipam deploy` workflow** (`.github/workflows/azure-ipam-deploy.yaml`), never
from a workstation. Why Azure IPAM, and how it fits with AVNM:
[docs/azure-ipam-plan.md](../docs/azure-ipam-plan.md).

| Root | Part | Runs as | Creates |
|------|------|---------|---------|
| [`entra/`](entra/) | 1 | the **entra** CI identity | the engine and UI app registrations, their service principals, tenant-wide consent, the engine's Reader role |
| [`platform/`](platform/) | 2 | the **platform** CI identity | App Service, Cosmos DB, Key Vault, Log Analytics, a managed identity; the engine's client secret; the UI's redirect URI. **Costs money; off by default** |

Part 1 makes the platform identity an **owner of both app registrations**. That's what lets
part 2 create the engine's client secret itself and put it straight into Key Vault. Unlike
`deploy.ps1 -AppsOnly`, **no secret is ever handed over**, and part 1's state holds none.

| Target | Does |
|--------|------|
| Actions → **azure-ipam deploy** | Plans, and applies a reviewed plan. The only way either part changes (below) |
| `make ipam-test` | `validate` + `terraform test` for both roots against mocked providers, and `ci.sh`'s tests. No Azure, no zip. CI runs it |
| `make ipam-fetch` | Downloads the pinned `ipam.zip` to `platform/.work/` and checks its SHA-256 (the workflow does too) |
| `make ipam-{entra,platform}-{init,plan}` | A local, read-only plan, for anyone with read access to the state |
| `make ipam-lock` | Regenerates both roots' `.terraform.lock.hcl` |

## The pin

[`platform/release.json`](platform/release.json) pins the release, its commit, the SHA-256 of its
`ipam.zip`, and the Python version the engine targets (`engine/app/version.json`). Terraform reads
it, and **refuses to plan a zip whose SHA-256 differs**, so a changed or missing asset stops the
deploy.

The app runs the zip **as it is**, with `WEBSITE_RUN_FROM_PACKAGE=1`. The zip's `packages/`
directory is built from upstream's lock file, so the zip's SHA-256 pins the dependencies too. The
other two ways upstream installs don't:

- `deploy.ps1 -Native` sets `SCM_DO_BUILD_DURING_DEPLOYMENT`, so App Service rebuilds with Oryx
  from the engine's **unpinned** `requirements.txt`.
- The default container install runs `azureipam.azurecr.io/ipam:latest`.

Run-from-package isn't new: `init.sh` and upstream's Bicep already use it for one cloud
(`AZURE_US_GOV_SECRET`).

## Differences from `deploy.ps1`

| Upstream | Here | Why |
|----------|------|-----|
| A person runs it, with Global Administrator | Two workload identities, from GitHub Actions only | reviewed, repeatable changes |
| Part 1 writes the engine secret into `main.parameters.json` for part 2 | Part 2 creates the secret, as an owner of the engine app | nothing secret changes hands |
| A placeholder SPA redirect URI, replaced after the deploy | Part 2 sets the real one; part 1 sets none | the placeholder does nothing |
| Oryx build from `requirements.txt` | run-from-package | pinned dependencies (above) |
| New resource names (and a new resource group) on every run | Stable names with one random suffix, kept in state | Terraform manages one install |
| Tenant id, client ids and identity id also stored in Key Vault | Plain app settings; only the secret is in Key Vault | they aren't secret |
| Cosmos DB key auth left on | Off | the engine uses the managed identity when `COSMOS_KEY` is unset, and nothing sets it |
| FTPS and TLS left at Azure's defaults | FTPS off, TLS 1.2 | hardening |
| Diagnostics: hand-picked log categories | `allLogs` category group | a superset that doesn't break on renames |
| The engine scope id is new on every run | One random id, kept in state | stable |
| Secret: 2 years, rotated by hand | 2 years, replaced by the first apply after one year | rotation without a calendar reminder |

Everything else mirrors v3.6.0: the same Graph and ARM permission ids, the three tenant-wide
consent grants, `api://<engine client id>`, v2 tokens, Reader at the tenant root, P1v3 Linux,
Python 3.11, `bash ./init.sh 8000`, `/api/status`, Cosmos DB `ipam-db`/`ipam-ctr` partitioned on
`/tenant_id` at up to 1000 RU/s, and the managed identity's roles.

## Deploying: GitHub Actions only

### How a change gets applied

The workflow runs by hand, from `main` only: **Actions → azure-ipam deploy → Run workflow**.

1. **Plan.** Pick the part and leave `reviewed_digest` empty. The job summary shows the plan
   and its **digest**, a SHA-256 of everything the plan would change. The digest is also a
   notice annotation, so `gh run view` shows it in a terminal.
2. **Review** the plan.
3. **Apply.** Run it again with the same part, the same `destroy` setting, and
   `reviewed_digest` set to that digest. It plans again and **applies only if the new plan has
   the same digest**. If anything changed in between (code on `main`, the state, or Azure),
   the digest changes and nothing is applied: plan and review again.

From a terminal, for part 1 (`part=platform` for part 2):

```sh
gh workflow run azure-ipam-deploy.yaml -R benoitnvl/scandula --ref main -f part=entra
gh run list -R benoitnvl/scandula --workflow azure-ipam-deploy.yaml --limit 1   # the run's id
gh run view <run id> -R benoitnvl/scandula         # the digest is a notice; --web shows the full plan
gh workflow run azure-ipam-deploy.yaml -R benoitnvl/scandula --ref main -f part=entra -f reviewed_digest=<digest>
```

GitHub environments and their required reviewers aren't available to private repos on GitHub
Free, so the digest is the approval step. Anyone who can run workflows (write access) can apply,
but only a plan they've seen.

⚠ **Part 2 costs about $170–250 a month** (P1v3 is about $134–158/month; Cosmos DB autoscale
about $9–88/month). It builds nothing until the repository variable `IPAM_ENABLED` is `true`.
Terraform also **refuses a credit or trial subscription**, or one with a spending limit on, and
the workflow never sets `allow_credit_subscription`.

Part 2 needs part 1: it reads part 1's outputs from part 1's state, which holds nothing
secret. Apply part 1 first, and destroy part 2 first.

### How it's trusted

- Each part runs as its **own Entra ID workload identity**, over **OIDC**. GitHub's short-lived
  token is exchanged for an Entra ID token, and no secret is stored anywhere.
- Both identities trust exactly one subject: **this workflow file, run from `main`**.
  That's
  `repo:benoitnvl/scandula:ref:refs/heads/main:job_workflow_ref:benoitnvl/scandula/.github/workflows/azure-ipam-deploy.yaml@refs/heads/main`,
  which needs the repository's OIDC subject to include `job_workflow_ref` (setup step 0).
- Trusting the branch alone (`…:ref:refs/heads/main`) **isn't enough**. `claude.yaml` also
  requests OIDC tokens (`id-token: write`), and its `@claude` responder runs from `main` on
  issue comments. It would get a token these identities accept, and a comment could steer
  what it does with it.
- **Each part's state has its own container**: `tfstate-azure-ipam-entra` and
  `tfstate-azure-ipam-platform`. That's what keeps applies in GitHub:
  - Only the entra identity can write part 1's state.
  - Only the platform identity can read or write part 2's, which holds the engine secret. The
    entra identity can't read it.
  - The platform identity can read part 1's state (for its outputs), but not write it.
  - People get Storage Blob Data Reader at most.

⚠ **The entra identity is very powerful.** The tenant-wide consent grants need Graph
`Directory.ReadWrite.All`, which makes it nearly as powerful as a Global Administrator. Any
change merged to `main` could use it. The digest gate means nothing is applied unreviewed, but
merges to `main` deserve the same care as the identity itself.

### One-time setup

**0. Put the workflow file in the OIDC subject** (a repository admin). This changes the subject
of every workflow's token in this repo:

```sh
gh api -X PUT repos/benoitnvl/scandula/actions/oidc/customization/sub --input - <<'EOF'
{"use_default": false, "include_claim_keys": ["repo", "context", "job_workflow_ref"]}
EOF
gh api repos/benoitnvl/scandula/actions/oidc/customization/sub   # check it took
```

`ci.yaml` doesn't use OIDC. `claude.yaml` does, to get its GitHub App token from Anthropic, and
it isn't verified that Anthropic accepts the new subject. **Check that the next Claude review
still posts.** If it doesn't, give `claude.yaml`'s jobs `github_token: ${{ secrets.GITHUB_TOKEN }}`
and drop their `id-token: write` (answers then come from github-actions[bot]). **Don't** reset the
subject template.

**1. Two identities** (an Aberdeen **Global Administrator**, in the Aberdeen tenant):

```sh
repo=benoitnvl/scandula
subject="repo:$repo:ref:refs/heads/main:job_workflow_ref:$repo/.github/workflows/azure-ipam-deploy.yaml@refs/heads/main"
graph=00000003-0000-0000-c000-000000000000

for part in entra platform; do
  app=$(az ad app create --display-name "scandula azure-ipam $part (GitHub Actions)" --query appId -o tsv)
  az ad sp create --id "$app" > /dev/null
  az ad app federated-credential create --id "$app" --parameters \
    "{\"name\":\"github-main\",\"issuer\":\"https://token.actions.githubusercontent.com\",\"subject\":\"$subject\",\"audiences\":[\"api://AzureADTokenExchange\"]}"
  echo "$part: $app"
done
entra_app=<entra appId>
platform_app=<platform appId>

# Graph application permissions (ids are Microsoft Graph's app roles), then admin consent.
#   entra:    Application.ReadWrite.All, Directory.ReadWrite.All (the tenant-wide consent grants)
#   platform: Application.ReadWrite.OwnedBy (the engine secret and the redirect URI, on apps it owns)
az ad app permission add --id "$entra_app" --api $graph --api-permissions \
  1bfefb4e-e0b5-418b-a88f-73c46d2cc8e9=Role 19dbc75e-c2e2-444c-a770-ec69d8559fc7=Role
az ad app permission add --id "$platform_app" --api $graph --api-permissions \
  18a4783c-866b-4cc7-a460-3d5e5662c884=Role
az ad app permission admin-consent --id "$entra_app"
az ad app permission admin-consent --id "$platform_app"
```

**2. Azure roles** (someone who can assign roles at these scopes):

```sh
tenant=<Aberdeen tenant id>
sub=<paid subscription id>
reader=acdd72a7-3385-48ef-bd42-f606fba81ae7

# entra: assign Reader, and only Reader, at the root management group (the engine's
# discovery role). Microsoft's condition for "may assign only these roles".
az role assignment create --assignee "$entra_app" \
  --role "Role Based Access Control Administrator" \
  --scope "/providers/Microsoft.Management/managementGroups/$tenant" \
  --condition-version 2.0 --condition \
  "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$reader})) AND ((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$reader}))"
az role assignment create --assignee "$entra_app" --role Reader --scope "/subscriptions/$sub"   # azurerm needs a subscription

# platform: Owner on the paid subscription (it creates role assignments), as upstream needs.
az role assignment create --assignee "$platform_app" --role Owner --scope "/subscriptions/$sub"

# Resource providers part 2 uses, once:
for rp in Microsoft.Web Microsoft.DocumentDB Microsoft.KeyVault Microsoft.ManagedIdentity \
          Microsoft.OperationalInsights Microsoft.Insights; do
  az provider register --subscription "$sub" --namespace "$rp"
done
```

**3. The state containers**, one per part, each writable only by its own identity:

```sh
account_id=$(az storage account show -n stscandulatfstate -g rg-scandula-tfstate --query id -o tsv)
containers="$account_id/blobServices/default/containers"
for part in entra platform; do
  az storage container create -n "tfstate-azure-ipam-$part" --account-name stscandulatfstate --auth-mode login
done
# Each identity writes its own state...
az role assignment create --assignee "$entra_app" --role "Storage Blob Data Contributor" \
  --scope "$containers/tfstate-azure-ipam-entra"
az role assignment create --assignee "$platform_app" --role "Storage Blob Data Contributor" \
  --scope "$containers/tfstate-azure-ipam-platform"
# ...and part 2 only reads part 1's (for its outputs). The entra identity gets nothing on
# part 2's container: that state holds the engine secret.
az role assignment create --assignee "$platform_app" --role "Storage Blob Data Reader" \
  --scope "$containers/tfstate-azure-ipam-entra"
```

**4. Repository variables** (not secrets: these are identifiers):

```sh
gh variable set AZURE_TENANT_ID          -R "$repo" --body "$tenant"
gh variable set AZURE_SUBSCRIPTION_ID    -R "$repo" --body "$sub"
gh variable set AZURE_CLIENT_ID_ENTRA    -R "$repo" --body "$entra_app"
gh variable set AZURE_CLIENT_ID_PLATFORM -R "$repo" --body "$platform_app"
gh variable set TFSTATE_SUBSCRIPTION_ID  -R "$repo" --body "<the state account's subscription>"
gh variable set TFSTATE_RESOURCE_GROUP   -R "$repo" --body rg-scandula-tfstate
gh variable set TFSTATE_STORAGE_ACCOUNT  -R "$repo" --body stscandulatfstate
gh variable set TFSTATE_CONTAINER_PREFIX -R "$repo" --body tfstate-azure-ipam   # + -entra / -platform
gh variable set IPAM_PLATFORM_OWNER_OBJECT_IDS -R "$repo" \
  --body "[\"$(az ad sp show --id "$platform_app" --query id -o tsv)\"]"
```

Optional variables:

| Variable | Part | Default | Use |
|----------|------|---------|-----|
| `IPAM_ENABLED` | 2 | `false` | **The cost guard.** `true` builds Azure IPAM |
| `IPAM_UI_ENABLED` | 1 | `true` | `false` for API only: no UI app, and no tenant-wide consent to `Directory.Read.All` |
| `IPAM_READER_MANAGEMENT_GROUP_ID` | 1 | the tenant root | narrows the engine's Reader role. Microsoft's docs discourage it |
| `IPAM_NAME_PREFIX`, `IPAM_LOCATION` | 2 | `scipam`, `eastasia` | naming and region (Southeast Asia is cheaper for P1v3) |
| `IPAM_ENGINE_APP_NAME`, `IPAM_UI_APP_NAME` | 1 | `scandula-ipam-engine`, `-ui` | app registration display names |

**5. Deploy:** plan and apply part 1, then set `IPAM_ENABLED=true` once the paid subscription is
ready, and plan and apply part 2. The part 2 run's job summary ends with its outputs; the URL is
`ipam_url`.

The first part 2 apply waits two minutes after granting itself Key Vault Secrets Officer,
because Key Vault role assignments take a while to arrive. If writing `ENGINE-SECRET` still
fails with a 403, plan and apply again.

## Configure it

Configure the address model in the Azure IPAM UI, or through its API, as in the plan:

1. **One space** for all of Aberdeen's address space.
2. **Blocks for the existing landing-zone ranges.** Associate each discovered VNet with its
   block.
3. **Blocks for the on-premises RFC 1918 ranges**, recorded as *external networks*
   (`/spaces/{space}/blocks/{block}/externals`).
4. **One block for AVNM**, matching `infra/`'s `ipam_root_prefix`. **Never make Azure IPAM
   reservations inside it.** AVNM can't see them.

Blocking the on-premises ranges needs Azure Policy (the plan's layer A): that's
`onprem_policy` in `infra/` (`infra/policy-onprem.tf`). Azure IPAM only records them.

## Upgrading

1. Update **everything in `release.json` together**, in a PR:

   ```sh
   v=v3.7.0   # the new release
   gh api "repos/Azure/ipam/git/ref/tags/$v" --jq .object.sha        # commit (a lightweight tag)
   gh api "repos/Azure/ipam/releases/tags/$v" \
     --jq '.assets[] | select(.name == "ipam.zip") | .digest'         # sha256:<zip_sha256>
   gh api "repos/Azure/ipam/contents/engine/app/version.json?ref=$v" \
     -H 'Accept: application/vnd.github.raw'                          # python_version
   ```

2. **Diff upstream's `deploy/` between the two releases** (`deploy.ps1`, `main.bicep`,
   `modules/`), and the engine's settings (`engine/app/globals.py`). These roots mirror v3.6.0: a
   new app setting, role or permission upstream needs a matching change here.
3. Merge, then plan and apply part 2 in the workflow. The zip's path includes the version, so
   the plan shows the web app redeploying.

## The engine secret

It's valid for two years, like upstream's. The first part 2 apply after it's a year old
replaces it (`time_rotating`), writes the new one to Key Vault, and removes the old one. So
**plan and apply part 2 at least once a year.** Its outputs show `engine_secret_end_date`.

## Teardown

With `destroy` ticked, in this order:

1. **Part 2** removes every Azure resource and the engine secret. (Setting `IPAM_ENABLED=false`
   and applying does the same.) Key Vault keeps the deleted vault for 90 days (purge protection),
   so its name stays reserved; a rebuild gets a new random suffix, so it doesn't collide.
2. **Part 1** removes the app registrations, their service principals, the consent grants and the
   Reader role. They're tenant objects, so they outlive part 2.

Then an administrator can remove the two CI identities themselves.

## Testing

`make ipam-test` runs `validate` and `terraform test` in both roots, against mocked `azuread`,
`azurerm`, `random` and `time` providers, and tests `ci.sh`.

- **Part 1** pins every value taken from `deploy.ps1`: permission and scope ids, the three consent
  grants and their tenant-wide scope, the token version, the identifier URI, the pre-authorized
  clients, and the wiring between the two apps.
- **Part 2** pins:
  - the app settings the engine reads (exactly, so an Oryx-build setting can't sneak in);
  - the runtime;
  - the Cosmos DB and Key Vault shape, and every role assignment;
  - the secret's lifetime and rotation;
  - the redirect URI;
  - that nothing is planned while `ipam_enabled` is off;
  - the credit-subscription refusal, and the zip SHA-256 check, which reads a stand-in zip in
    `platform/tests/fixtures/` for real.
- **`ci.sh`** (`scripts/test-azure-ipam-ci.sh`, against a stub `terraform`) pins:
  - how repository variables become Terraform inputs: the cost guard defaults off, and a line
    break can't inject a variable;
  - the backend settings over OIDC, and that part 2 reads part 1's outputs;
  - the plan digest: it ignores key order and the timestamp, but not a change.
- `actionlint` checks the workflow. `make mutants` disables each validation in turn, in every
  root, and demands a red run.

What none of it **can** prove: that Entra and Azure accept these objects, that GitHub's OIDC
token gets through, and that the engine starts and signs users in. Only a real run proves that.
