# Plan: a second deployment, Azure IPAM (`Azure/ipam`)

**Status: plan only.** Nothing here is deployed or coded yet. Four decisions below need an
answer first.

This would be a second, separate deployment alongside the Terraform in `infra/`: Microsoft's
open-source [Azure IPAM](https://github.com/Azure/ipam), in the same subscription and the same
region (East Asia).

## What Azure IPAM is

A web app (a UI plus an engine API) that discovers VNets, subnets and endpoints across the
tenant, using the engine's Reader role and Azure Resource Graph. You define *spaces* and
*blocks* of address space, and reserve CIDRs through the UI or its API.

- Repo: `Azure/ipam`, MIT licence, actively committed. Latest release **v3.6.0
  (2025-09-11)**.
- Installed by a PowerShell script (`deploy/deploy.ps1`) driving Bicep. **There's no
  Terraform installer.** `examples/ipam-terraform` shows how to *consume* the API (reserve a
  CIDR for a new VNet); it doesn't deploy Azure IPAM.
- **It is not AVNM IPAM.** It's a separate product with its own database, and its docs don't
  mention AVNM at all. The two don't talk to each other.

## Decision 1: which IPAM is the authority?

scandula already has AVNM IPAM (`infra/ipam.tf`): a root pool `10.64.0.0/12`, region pools,
and the hub reservations. Azure enforces those allocations on VNets. Running Azure IPAM as
well means two address inventories, so one of them has to lead.

| Option | What it means | Cost to the design |
|--------|---------------|--------------------|
| **A. AVNM stays the authority; Azure IPAM is for visibility** *(recommended)* | Spokes keep allocating from AVNM pools. Azure IPAM mirrors them as spaces/blocks for tenant-wide discovery and reporting. | Mirrored by hand or via API, with no enforcement from Azure IPAM's side. |
| B. Azure IPAM allocates spokes; AVNM only reserves hubs | Spokes get CIDRs from Azure IPAM's API (as in its Terraform example) instead of AVNM pools. | Two systems each hold part of the truth; the region pools would have to exclude whatever Azure IPAM hands out. |
| C. Replace AVNM IPAM | Remove `infra/ipam.tf`; Azure IPAM is the only inventory. | Loses Azure-enforced non-overlap and the plan-time validations in `infra/variables.tf`. |

## What it deploys

Into its own resource group, from `deploy/main.bicep` (subscription scope):

| Resource | Notes |
|----------|-------|
| App Service plan **P1v3** (Linux) + App Service | Runs the IPAM container. P1v3 is **hard-coded** in `appService.bicep`; `-Function` swaps in an Elastic Premium Function instead. |
| Cosmos DB (SQL API) | Autoscale, max 1000 RU/s |
| Key Vault | Engine client secret, app IDs, tenant ID |
| Log Analytics workspace | Diagnostics for everything above |
| User-assigned managed identity | **Contributor** and **Managed Identity Operator** on the subscription |
| Storage account | Function mode only |
| Container registry | Only with `-PrivateACR` |

And in the Entra ID tenant (`deploy.ps1`):

- **Engine** app registration + service principal: **Reader at the root management group**
  (`-MgmtGroupId` overrides that), and a client secret valid for **2 years**.
- **UI** app registration + service principal (skipped with `-DisableUI`): Microsoft Graph
  `User.Read` + `Directory.Read.All`, and Azure Service Management `user_impersonation`.
  These need **admin consent**.

## Decision 2: who can install it?

`deploy.ps1` needs all three of:

1. **Owner** on the subscription.
2. **Owner**, **User Access Administrator** or a custom `roleAssignments/write` role **at the
   tenant root management group**, to grant the engine its Reader role.
3. **Global Administrator**, for admin consent on the app registrations.

benoit@nuvulu.cloud currently has Contributor + User Access Administrator on `Aberdeen_VSPS`,
and isn't Global Administrator. So **a single-pass install isn't possible from this account.**
Azure IPAM supports that case with a two-part install:

- **Part 1 (identities)**, run by an Aberdeen tenant administrator: `deploy.ps1 -AppsOnly`.
  It creates the app registrations and role assignments, and writes `main.parameters.json`.
- **Part 2 (infrastructure)**, run by us: `deploy.ps1 -ParameterFile main.parameters.json`.
  It needs subscription-level role-assignment rights. Contributor + User Access Administrator
  inherited from `Aberdeen_VSPS` should cover what Owner is asked for here; confirm on the
  first run.

⚠ `main.parameters.json` carries the engine's client secret. It must be handed over securely
and never committed.

`-MgmtGroupId Aberdeen_VSPS` would scope the engine's Reader role to Aberdeen's management group
instead of the whole tenant. Microsoft's docs *highly discourage* a non-root group, but it
keeps discovery inside Aberdeen, so it's worth deciding deliberately.

## Decision 3: cost

Azure retail prices, East Asia, checked 2026-09-11:

| Item | Price |
|------|-------|
| App Service P1v3 Linux | $0.217/h, **about $158/month** (Southeast Asia: $134) |
| Cosmos DB autoscale, 100–1000 RU/s | about $9–88/month, depending on load (100 RU/s standard is $0.008/h; autoscale bills at 1.5× that) |
| Log Analytics, Key Vault | small; ingestion- and operation-based |

**Total: roughly $170–250 a month, running all the time.** The current subscription is a Visual
Studio credit subscription ($50/month, spending limit on). That would run out in about a week,
and Azure would then disable the subscription, **including the tfstate storage account**. Like
the secured hubs, this needs a paid subscription.

P0v3 ($79/month in East Asia) would roughly halve the App Service cost, but it isn't a
supported parameter. It would mean changing the upstream Bicep.

## Decision 4: how this repo runs it

| Option | How | Trade-off |
|--------|-----|-----------|
| **1. Upstream script, pinned** *(recommended)* | An `azure-ipam/` folder with a runbook and Makefile targets that clone `Azure/ipam` at tag `v3.6.0` and run `deploy.ps1` with checked-in, non-secret options (`-Location eastasia`, `-NamePrefix`, `-Tags`). | Microsoft's supported path, and `update.ps1` upgrades work. But it's outside Terraform state: ARM owns it, not `infra/`. |
| 2. Terraform wrapper | `azurerm_resource_group_template_deployment` with ARM compiled from the pinned Bicep, and the `azuread` provider for the app registrations. | Everything is in Terraform state, but it's no longer the supported install path, and upgrades become ours to port. |
| 3. Native Terraform rewrite | Resources written directly in `azurerm`/`azuread`. | Full control (P0v3, naming, tests), but the most work, with ongoing drift from upstream. |

Nothing in options 1–3 would be tested in CI the way `infra/` is. Azure IPAM's resources aren't
in scandula's Terraform tests.

## Steps, once the decisions are made

1. **Decide** 1 (authority), 2 (who runs part 1, and at which management group), 3 (paid
   subscription), and 4 (how).
2. **Part 1:** an Aberdeen tenant admin runs `deploy.ps1 -AppsOnly -Location eastasia
   -UIAppName <name> -EngineAppName <name> [-MgmtGroupId <mg>]` from a `v3.6.0` checkout, and
   hands over `main.parameters.json` securely.
3. **Part 2:** we run `deploy.ps1 -ParameterFile main.parameters.json -Location eastasia
   -NamePrefix <prefix> -Tags @{repo = 'benoitnvl/scandula'}`.
4. **Configure**: with option A, a space for `10.64.0.0/12` with blocks for the `eas` and
   `sea` region pools, matching `infra/`.
5. **Operate**:
   - Rotate the engine secret before its 2-year expiry. Put that in the runbook, because
     nothing reminds you.
   - Upgrade with `update.ps1`.
6. **Teardown**, if ever: delete the resource group *and* the two app registrations. The app
   registrations are tenant objects and outlive the resource group.

## Open questions

- Is Azure IPAM needed at all, given AVNM IPAM? It adds tenant-wide discovery and a UI.
  AVNM IPAM already enforces the plan that scandula owns.
- Who in Aberdeen can run part 1 (Global Administrator plus the root management group), and
  will they approve `Directory.Read.All`?
- Tenant-wide discovery (root management group), or `Aberdeen_VSPS` only?
- UI or API only (`-DisableUI`)? API only needs no Graph `Directory.Read.All` consent.
- Which paid subscription?
