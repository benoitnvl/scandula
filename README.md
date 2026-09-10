# scandula

Terraform for Aberdeen's **Azure connectivity core**: a **secured Virtual WAN** (one
Standard hub per region, each with an Azure Firewall and routing intent), with the
address plan owned by **Azure Virtual Network Manager (AVNM) IPAM**.

This is an Aberdeen project. It isn't part of the benoitnvl homelab estate and shares
nothing with it: no address space, DNS or connectivity.

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
| Firewall policy | `afwp-scandula` | shared by every hub; no rules yet, so default deny |
| Azure Firewall | `afw-scandula-<region>` | `AZFW_Hub`, tier `firewall_sku_tier` (default **Basic**) |
| Routing intent | `ri-scandula-<region>` | internet **and** private traffic through that hub's firewall |

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
  outputs.tf         pool ids, hub ids + firewall IPs, policy id
  tests/             terraform test — mocked azurerm, no credentials
  backend.hcl.example
  terraform.tfvars.example
docs/
  bootstrap.md       one-time: state account, RP registration, first apply
  design.md          topology, address plan, cost, what's deliberately not here yet
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
when it's on (hubs, firewalls, routing intent), and that every validation rejects
what it should. `make mutants` proves each validation is load-bearing.

CI (GitHub-hosted `ubuntu-latest`: stazzona has no runner scale set for this repo) runs
`terraform fmt -check`, `validate`, `test` and a trivy misconfig + secret scan on every
PR. **CI never touches Azure.** `make apply` from a workstation is the only write path.
