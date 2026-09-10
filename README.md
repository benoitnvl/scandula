# scandula

Terraform for the estate's **Azure connectivity core**: one hub VNet per region,
with every address handed out by **Azure Virtual Network Manager (AVNM) IPAM**,
and AVNM connectivity configurations wiring spokes to their hub and hubs to each
other.

One platform, one repo, like the rest of the estate:

| Repo | Platform | Provisions |
|------|----------|-----------|
| `bonifaziu` | Proxmox host | VMs + LXCs |
| `torra` | on-prem Talos k8s | app workloads (Flux) |
| `nonza` | DMZ Debian box | Caddy edge |
| `stazzona` | Talos VM on bonifaziu | CI runners (ARC) |
| `Mortella` | UniFi UDM | VLANs, DNS, firewall |
| **`scandula`** | **Azure** | **network hubs, AVNM, IPAM** |

## What it builds

| Resource | Name | Notes |
|----------|------|-------|
| Resource group | `rg-scandula-connectivity` | control plane, in `var.location` |
| Network manager | `avnm-scandula` | scoped to the current subscription unless told otherwise |
| IPAM root pool | `ipam-scandula-root` | `ipam_root_prefix` — default `10.64.0.0/12` |
| IPAM region pool | `ipam-scandula-<region>` | a child of root, one per region |
| Hub VNet | `vnet-scandula-hub-<region>` | its address space is **allocated from its region pool**, never hardcoded |
| Hub subnets | `GatewaySubnet`, `AzureFirewallSubnet`, `AzureFirewallManagementSubnet`, `AzureBastionSubnet` | also allocated from the pool (/26 each by default) |
| Network group | `ng-spokes-<region>` | spokes join from their own repos |
| Connectivity config | `cc-hubspoke-<region>` | hub-and-spoke per region |
| Network group + config | `ng-hubs`, `cc-hub-mesh` | global mesh between hubs — only with 2+ regions |
| Deployment | one per region | commits that region's configs (nothing is live until deployed) |

The address plan and the reasoning behind it are in [docs/design.md](docs/design.md).

## Layout

```
infra/
  versions.tf        terraform >= 1.9, azurerm ~> 5.4, azurerm backend (partial)
  providers.tf
  variables.tf       inputs + the CIDR sanity checks (containment, overlap, sizing)
  locals.tf
  main.tf            resource groups, network manager
  ipam.tf            root pool, region pools, static CIDRs
  hubs.tf            hub VNets + subnets, all IPAM-allocated
  connectivity.tf    network groups, hub-and-spoke + hub mesh, deployments
  outputs.tf         pool ids, hub VNets (with allocated prefixes), spoke group ids
  tests/             terraform test — mocked azurerm, no credentials
  backend.hcl.example
  terraform.tfvars.example
docs/
  bootstrap.md       one-time: state account, RP registration, first apply
  design.md          address plan, topology, what's deliberately not here yet
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
checks what gets built (pools, hubs, which configs each region commits) and that
every CIDR validation rejects what it should.

CI (GitHub-hosted `ubuntu-latest`: stazzona has no runner scale set for this repo) runs
`terraform fmt -check`, `validate`, `test` and a trivy misconfig + secret scan on every PR. **CI never touches Azure.** `make apply` from a
workstation is the only write path.
