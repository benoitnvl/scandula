# scandula

Terraform for Aberdeen's **Azure connectivity core**: a **secured Virtual WAN** (one
Standard hub per region, each with an Azure Firewall and routing intent), addressed from
**Azure Virtual Network Manager (AVNM) IPAM**. AVNM runs **one block**, delegated to it by
**NetBox**, which is the authority for all of Aberdeen's address space
([docs/netbox-plan.md](docs/netbox-plan.md)).

This is an Aberdeen project. It isn't part of the benoitnvl homelab estate and shares
nothing with it: no address space, DNS or connectivity.

![scandula architecture: Azure IPAM delegates one block to scandula's AVNM IPAM pools, and a secured Virtual WAN with hubs in East Asia and Southeast Asia, each with an Azure Firewall that denies by default and logs to a workspace, routing intent, and the shared policy](docs/diagrams/architecture.svg)

Source: [`docs/diagrams/architecture.drawio`](docs/diagrams/architecture.drawio). Edit it in
draw.io, then run `make diagram` to re-export the SVG. The SVG embeds the diagram, so it
also opens directly in draw.io.

## What it builds

Always:

| Resource | Name | Notes |
|----------|------|-------|
| Resource group | `rg-scandula-connectivity` | control plane, in `var.location` |
| Network manager | `avnm-scandula` | IPAM only; scoped to the current subscription unless told otherwise |
| IPAM root pool | `ipam-scandula-root` | `ipam_root_prefix` — default `10.64.0.0/12` |
| IPAM region pool | `ipam-scandula-<region>` | a child of root, one per region; spokes allocate from it |
| Hub reservation | static CIDR `vhub-<region>` | the region's hub range, reserved so no spoke gets it |

Only with **`secured_vwan_enabled = true`** (off by default — about **$470/month per
hub**, see [docs/design.md](docs/design.md#cost)):

| Resource | Name | Notes |
|----------|------|-------|
| Resource group | `rg-scandula-vwan` | in `var.location` |
| Virtual WAN | `vwan-scandula` | Standard (Basic can't host a firewall) |
| Virtual hub | `vhub-scandula-<region>` | Standard, on `hub_address_prefix` |
| Firewall policy | `afwp-scandula` | shared by every hub |
| Rule collection group | `rcg-baseline` | only the flows and destinations named in `east_west_flows` / `egress_*`; everything else denied. Not created when nothing is named |
| Log Analytics workspace | `log-scandula-hub` | the hub firewalls' logs (`allLogs`, dedicated tables); `firewall_diagnostics_enabled` |
| Azure Firewall | `afw-scandula-<region>` | `AZFW_Hub`, tier `firewall_sku_tier` (default **Basic**) |
| Routing intent | `ri-scandula-<region>` | internet **and** private traffic through that hub's firewall |

Only with **`onprem_policy.management_group_id`** set (off by default: it reaches every VNet
under that management group; see [layer A of the plan](docs/azure-ipam-plan.md#layer-a-on-premises-ranges-everywhere-from-day-one)):

| Resource | Name | Notes |
|----------|------|-------|
| Policy definition | `scandula-deny-onprem-overlap` | at that management group: no VNet may overlap a `reserved_prefixes` range |
| Policy assignment | `scandula-onprem` | same management group; effect **Audit** until `onprem_policy.effect = "Deny"` |

Only with **`avnm_allocation_policy.management_group_id`** set (off by default; see [layer B of
the plan](docs/azure-ipam-plan.md#layer-b-avnm-only-allocation-per-migrated-scope)):

| Resource | Name | Notes |
|----------|------|-------|
| Policy definition | `scandula-require-avnm-allocation` | at that management group: a VNet must hold an allocation from the region pools, and none from any other pool |
| Policy assignment | `avnm-<key>` | one per migrated scope in `assignments` (management group or subscription), each **Audit** until its `effect = "Deny"` |

## Layout

```
infra/
  versions.tf        terraform >= 1.9, azurerm ~> 5.4, azurerm backend (partial)
  providers.tf
  variables.tf       inputs + the CIDR sanity checks (containment, overlap, sizing)
  locals.tf
  main.tf            control-plane resource group, network manager
  ipam.tf            root pool, region pools, hub reservations, static CIDRs
  vwan.tf            vWAN, hubs, firewall policy, hub firewalls, routing intent (gated)
  firewall-rules.tf  baseline rule collection group on the shared policy (gated)
  policy-onprem.tf   Azure Policy: no VNet may overlap reserved_prefixes (gated)
  policy-avnm.tf     Azure Policy: VNets in migrated scopes must allocate from AVNM IPAM (gated)
  outputs.tf         pool ids, hub ids + firewall IPs, firewall policy id, policy ids
  tests/             terraform test — mocked azurerm, no credentials
  backend.hcl.example
  terraform.tfvars.example
netbox/              the address authority (`make netbox-*`; runbook in its README)
  platform/          NetBox on Azure Container Apps + PostgreSQL + Redis (gated: costs money)
  records/           the address plan as data, through the NetBox API
azure-ipam/          ⚠ DORMANT — Microsoft's Azure IPAM, which NetBox replaced. Never
                     applied; kept as the fallback. Don't dispatch its workflow
docs/
  bootstrap.md       one-time: state account, RP registration, first apply
  design.md          topology, address plan, cost, what's deliberately not here yet
  netbox-plan.md     the address authority: NetBox, what AVNM keeps, the version pin
  azure-ipam-plan.md superseded by netbox-plan.md; kept for the dormant azure-ipam/ roots
  zero-trust.md      plan: default-deny east-west, an egress allow-list, guardrail policies
  diagrams/          architecture + zero-trust .drawio sources and their .svg exports (`make diagram`)
scripts/
  validation-mutants.py   `make mutants`: proves every validation is actually tested
```

## Quickstart

First time only: [docs/bootstrap.md](docs/bootstrap.md). After that:

```sh
export ARM_SUBSCRIPTION_ID=<connectivity subscription>
az login
make init     # against the Azure Storage backend
make plan     # writes infra/tfplan
make apply    # applies exactly that plan
```

## Tests and CI

```sh
make init-local && make test
```

`terraform test` runs against a **mocked azurerm**, so it needs no Azure access. It
checks that nothing billable is planned while the cost guard is off, what gets built
when it's on (hubs, firewalls, routing intent), the on-premises policy's wiring and rule,
and that every validation rejects what it should. `make mutants` proves each validation
is load-bearing.

CI (GitHub-hosted `ubuntu-latest`: stazzona has no runner scale set for this repo) runs
`terraform fmt -check`, then `validate` + `test` for `infra/`, both NetBox roots and both
(dormant) Azure IPAM roots, and a
trivy misconfig + secret scan, on every PR. **`ci.yaml` never touches Azure.** For `infra/`, `make apply` from a workstation
is the only write path, and the same for NetBox (`make netbox-plan` → `make netbox-apply`).
Azure IPAM was the other way round: it's applied **only** by the manual
`azure-ipam deploy` workflow, over OIDC, and only with the digest of a reviewed plan
([azure-ipam/README.md](azure-ipam/README.md#deploying-github-actions-only)).

A separate `claude` workflow has Claude review every non-draft PR and answer `@claude`
comments. It authenticates with the `CLAUDE_CODE_OAUTH_TOKEN` repo secret, so its usage
counts against the Claude subscription that created the token. A green `claude` check isn't
proof of a review; the review posted on the PR is. A PR that edits `claude.yaml` can't run
the review at all.
