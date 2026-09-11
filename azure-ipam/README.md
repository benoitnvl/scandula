# Azure IPAM runbook

How scandula deploys Microsoft's [Azure IPAM](https://github.com/Azure/ipam): the address
authority described in [`docs/azure-ipam-plan.md`](../docs/azure-ipam-plan.md). The work is
done by `ipam.sh`, driven by these `make` targets:

| Target | What it does | Who runs it |
|--------|--------------|-------------|
| `make ipam-fetch` | Clones the pinned upstream release, verifies its commit, and downloads and verifies the release zip | anyone |
| `make ipam-check` | Checks PowerShell, the Az and Microsoft Graph modules, Bicep, and the Azure PowerShell context | anyone |
| `make ipam-apps` | **Part 1**: creates the Entra ID app registrations, and writes `.work/main.parameters.json` | an Aberdeen tenant admin |
| `make ipam-infra` | **Part 2**: deploys the infrastructure. **Costs money**, so it's guarded | us |
| `make ipam-update` | Zip-deploys the pinned release to an existing install | us |
| `make ipam-test` | Tests `ipam.sh` against stubs: no Azure, no network | anyone, and CI |

Nothing here is Terraform. Azure IPAM's resources live outside `infra/` and its state, and
ARM owns them.

## The pin, and why "native"

`settings.sh` pins all three of these, and `ipam-fetch` checks all three on every run:

| | Value |
|--|--|
| Release | `v3.6.0` |
| Commit | `12e41f4b93a7e5f3c61a859428c32137440037b2` (the tag is lightweight) |
| `ipam.zip` SHA-256 | `0ac8d7cb95eb7b3b13622470aff42a26bda8a3233689938ac16b042ab31c4abe` (GitHub's digest for the release asset) |

The wrapper always installs **native**: `deploy.ps1 -Native -ZipFilePath <the verified zip>`.
Two upstream defaults would silently ignore the pin:

- The default **container** install runs `azureipam.azurecr.io/ipam:latest`.
- `update.ps1` without `-ZipFilePath` downloads **`releases/latest`**.

## Prerequisites

- **PowerShell 7.2+** (`pwsh`), **Azure PowerShell (Az) 8.0+** (11.4+ recommended), `git`, `curl`.
- **Part 1** also needs **Microsoft Graph PowerShell 2.0+**. The person running it needs
  **Global Administrator**, plus Owner or User Access Administrator at the management group
  the engine will read. By default that's the tenant root.
- **Part 2** also needs the **Bicep CLI 0.21.1+**, and **Owner** (or Contributor + User Access
  Administrator) on the target subscription.
- Signed in to Azure PowerShell, on the right subscription:

  ```powershell
  Connect-AzAccount
  Set-AzContext -Subscription <target subscription id>
  ```

`make ipam-check` confirms all of this, and prints the subscription and tenant it would use.

## Settings

`settings.sh` holds the committed, non-secret defaults. An environment variable of the same
name overrides each one:

| Setting | Default | Notes |
|---------|---------|-------|
| `IPAM_LOCATION` | `eastasia` | The same region as the control plane |
| `IPAM_NAME_PREFIX` | `scipam` | 1–7 lowercase letters/digits (`deploy.ps1`'s limit) |
| `IPAM_UI_APP_NAME` / `IPAM_ENGINE_APP_NAME` | `scandula-ipam-ui` / `scandula-ipam-engine` | App registration names |
| `IPAM_MGMT_GROUP` | *(empty = tenant root)* | Must cover every landing-zone subscription; see the plan's decision 1 |
| `IPAM_DISABLE_UI` | `false` | `true` = API only, so no Graph `Directory.Read.All` consent |

Every value is checked against a strict pattern before it goes anywhere near PowerShell.

## Part 1: identities (an Aberdeen tenant admin)

```sh
make ipam-check
make ipam-apps          # IPAM_MGMT_GROUP=<mg> / IPAM_DISABLE_UI=true to override
```

1. `deploy.ps1 -AppsOnly` creates the UI and engine app registrations, grants the engine
   **Reader** at the management group, and asks for **admin consent**.
2. `main.parameters.json` lands in `azure-ipam/.work/`, with mode `600`. **It contains the
   engine's client secret.** Git ignores it and the wrapper never prints it.
3. Hand it to whoever runs part 2 over a secure channel, such as a Key Vault secret or an
   encrypted share. Never email it, paste it into chat, or commit it.

The wrapper refuses to run part 1 again while that file exists, rather than overwrite a secret
that may already have been handed over.

## Part 2: infrastructure (us)

Put the parameter file at `azure-ipam/.work/main.parameters.json`, or point
`IPAM_PARAMETER_FILE` at it. Then:

```sh
make ipam-check
IPAM_CONFIRM_COST=yes make ipam-infra
```

This deploys a P1v3 App Service (native, from the verified zip), Cosmos DB, Key Vault, Log
Analytics and a managed identity: **about $170–250/month**. Guards:

- It **won't run without `IPAM_CONFIRM_COST=yes`**.
- It **refuses credit and trial subscriptions**, such as Visual Studio `MSDN_*`: with a spending
  limit, the credit runs out within days and the whole subscription is disabled, tfstate
  included. `IPAM_ALLOW_CREDIT_SUBSCRIPTION=yes` overrides that, deliberately.
- It **needs the parameter file** from part 1.

Afterwards, open the App Service's URL and sign in. Check the engine discovers the
landing-zone VNets.

## Configure (the plan's model)

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

1. Pick the new release, and update all three pins in `settings.sh` in a PR:

   ```sh
   gh api repos/Azure/ipam/git/ref/tags/<tag> --jq .object.sha             # IPAM_COMMIT (lightweight tag)
   gh api repos/Azure/ipam/releases/tags/<tag> --jq '.assets[].digest'     # IPAM_ZIP_SHA256
   ```

   Read the release notes for migration steps first. Some upgrades change the Bicep and need
   part 2 re-run, not just a zip deploy.
2. After merging:

   ```sh
   IPAM_APP_NAME=<app service> IPAM_RESOURCE_GROUP=<rg> make ipam-update
   ```

## Rotating the engine secret

Part 1 gives the engine app registration a client secret valid for **2 years**. Nothing
reminds you before it expires, so put the date in the team calendar. Rotating it means a new
secret on the engine app registration, the Key Vault secret updated to match, and the app
restarted. Follow Azure IPAM's own docs for the current steps.

## Teardown

Delete the resource group **and** both app registrations. The app registrations are tenant
objects, and they outlive the resource group.

## Testing

`make ipam-test` runs `scripts/test-azure-ipam.sh`. It puts stub `pwsh`, `git`, `curl` and
`bicep` on the PATH, and asserts:

- the exact command every target runs;
- that each pin and guard refuses when it should;
- that the secret never reaches the output.

CI runs it with shellcheck.

What it **can't** prove is that Microsoft's `deploy.ps1` accepts those commands. That was checked
by reading its `v3.6.0` parameter sets, and only a real run proves it.
