# Azure IPAM, as Terraform

Microsoft's [Azure IPAM](https://github.com/Azure/ipam) (`Azure/ipam`), deployed by two
Terraform roots instead of its PowerShell installer (`deploy.ps1` + Bicep). They reproduce what
`deploy.ps1` creates at release **v3.6.0**, with the differences listed below. Why Azure IPAM,
and how it fits with AVNM: [docs/azure-ipam-plan.md](../docs/azure-ipam-plan.md).

| Root | Part | Run by | Creates |
|------|------|--------|---------|
| [`entra/`](entra/) | 1 | an Aberdeen tenant administrator | the engine and UI app registrations, their service principals, tenant-wide consent, the engine's Reader role |
| [`platform/`](platform/) | 2 | us | App Service, Cosmos DB, Key Vault, Log Analytics, a managed identity; the engine's client secret; the UI's redirect URI. **Costs money; off by default** |

Part 1 makes part 2's identities **owners of both app registrations**. That's what lets part 2
create the engine's client secret itself and put it straight into Key Vault. Unlike
`deploy.ps1 -AppsOnly`, **no secret is ever handed over**, and part 1's state holds none.

| Target | Does | Who |
|--------|------|-----|
| `make ipam-fetch` | Downloads the pinned `ipam.zip` to `platform/.work/` and checks its SHA-256 | us |
| `make ipam-entra-init` / `-plan` / `-apply` | Part 1 | tenant admin |
| `make ipam-platform-init` / `-plan` / `-apply` | Part 2 | us |
| `make ipam-test` | `validate` + `terraform test` for both roots, against mocked providers: no Azure, no zip | anyone, and CI |
| `make ipam-lock` | Regenerates both roots' `.terraform.lock.hcl` | whoever bumps a provider |

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

## Part 1: Entra ID (an Aberdeen tenant administrator)

Needs, all as the person running it:

- **Global Administrator**, for the tenant-wide (AllPrincipals) consent grants.
- A role that can **assign roles at the management group** the engine reads, by default the
  tenant root: Owner, User Access Administrator, or a custom role with
  `Microsoft.Authorization/roleAssignments/write`.
- Terraform ≥ 1.9, the Azure CLI, and `az login`. `ARM_SUBSCRIPTION_ID` can be any subscription
  they can see: azurerm needs one, though the only Azure resource here is a management-group role
  assignment.
- Access to the state: Storage Blob Data Contributor on the `tfstate` container (see
  `entra/backend.hcl.example`), or a backend of their own.

```sh
cp azure-ipam/entra/backend.hcl.example     azure-ipam/entra/backend.hcl
cp azure-ipam/entra/terraform.tfvars.example azure-ipam/entra/terraform.tfvars
# set platform_owner_object_ids: the object id(s) of whoever runs part 2
make ipam-entra-init
make ipam-entra-plan
make ipam-entra-apply
terraform -chdir=azure-ipam/entra output
```

Hand the outputs to whoever runs part 2. **None of them is secret.**

Options, in `terraform.tfvars`:

- `ui_enabled = false` gives an API-only install: no UI app, and no tenant-wide consent to Graph
  `Directory.Read.All`, which only the UI needs.
- `reader_management_group_id` narrows the engine's Reader role. Microsoft's docs discourage
  anything narrower than the tenant root: the engine can only see VNets under it.

## Part 2: the platform (us)

⚠ **About $170–250 a month, running all the time** (P1v3 is about $134–158/month; Cosmos DB
autoscale about $9–88/month). Two guards:

- `ipam_enabled` is **false** by default, and the tests assert that nothing is planned while it
  is.
- Terraform **refuses a credit or trial subscription**, or any with a spending limit on, unless
  `allow_credit_subscription = true`. On the Visual Studio subscription, Azure IPAM would use up
  the credit in about a week, and Azure would then disable the subscription, tfstate account
  included.

Needs:

- A **paid subscription**, with **Owner** (part 2 creates role assignments), as
  `ARM_SUBSCRIPTION_ID`.
- To be signed in as an identity listed in part 1's `platform_owner_object_ids`.
- These resource providers, registered once:

  ```sh
  for rp in Microsoft.Web Microsoft.DocumentDB Microsoft.KeyVault Microsoft.ManagedIdentity \
            Microsoft.OperationalInsights Microsoft.Insights; do
    az provider register --namespace "$rp"
  done
  ```

```sh
cp azure-ipam/platform/backend.hcl.example     azure-ipam/platform/backend.hcl
cp azure-ipam/platform/terraform.tfvars.example azure-ipam/platform/terraform.tfvars
# fill in part 1's outputs; set ipam_enabled = true
make ipam-fetch
make ipam-platform-init
make ipam-platform-plan
make ipam-platform-apply
terraform -chdir=azure-ipam/platform output ipam_url
```

The first apply waits two minutes after granting itself Key Vault Secrets Officer, because Key
Vault role assignments take a while to arrive. If writing `ENGINE-SECRET` still fails with a 403,
run the plan and apply again.

⚠ **Part 2's state holds the engine's client secret** (the password, and the Key Vault secret).
Only the people who run part 2 should be able to read `azure-ipam-platform.tfstate`.

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
3. `make ipam-fetch`, then `make ipam-platform-plan`. The zip's path includes the version, so the
   plan shows the web app redeploying. Then `make ipam-platform-apply`.

## The engine secret

It's valid for two years, like upstream's. The first `make ipam-platform-apply` after it's a year
old replaces it (`time_rotating`), writes the new one to Key Vault, and removes the old one. So
**run an apply at least once a year.** `terraform -chdir=azure-ipam/platform output
engine_secret_end_date` shows the current expiry.

## Teardown

1. Part 2: set `ipam_enabled = false`, then plan and apply. That removes every Azure resource and
   the engine secret.
   - Key Vault keeps the deleted vault for 90 days (purge protection), so its name stays reserved.
     A rebuild gets a new random suffix, so it doesn't collide.
2. Part 1: `terraform -chdir=azure-ipam/entra destroy`, run by the tenant administrator. That
   removes the app registrations, their service principals, the consent grants and the Reader
   role. They're tenant objects, so they outlive part 2.

## Testing

`make ipam-test` runs `validate` and `terraform test` in both roots, against mocked `azuread`,
`azurerm`, `random` and `time` providers.

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
- `make mutants` disables each validation in turn, in every root, and demands a red run.

What the mocks **can't** prove: that Entra and Azure accept these objects, and that the engine
starts and signs users in. Only a real run proves that, and it needs a Global Administrator and a
paid subscription.
