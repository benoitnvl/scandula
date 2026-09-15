# A spoke, addressed from AVNM IPAM

Copy this into the repo that owns the spoke. **It is never applied from scandula** —
there's no backend block and no `make apply` target for it; scandula builds the
connectivity core, and each workload team builds its own spokes.

What it shows is the answer to "how do we get a range?": you don't pick one. The
VNet and every subnet ask the region's IPAM pool for a **number of addresses**, and
AVNM picks the prefix. Nothing here contains a CIDR, and the test suite asserts that.

```hcl
resource "azurerm_virtual_network" "this" {
  # no address_space
  ip_address_pool {
    id                     = var.ipam_pool_id
    number_of_ip_addresses = "1024"   # a /22. The API takes a string.
  }
}
```

The allocated range is known only after apply, from
`ip_address_pool[0].allocated_ip_address_prefixes` — the `address_prefixes` and
`subnet_address_prefixes` outputs here.

## Why allocate instead of picking

- **Two teams can't take the same range.** The pool hands out each prefix once.
- **The guardrail policy passes by construction.** Layer B
  ([docs/azure-ipam-plan.md](../../docs/azure-ipam-plan.md#layer-b-avnm-only-allocation-per-migrated-scope))
  denies any VNet in a migrated scope that holds no allocation from scandula's region
  pools. A hand-picked range is exactly what it refuses.
- **Azure IPAM stays right.** It's the authority for all of Aberdeen's address space and
  has delegated one block to AVNM. Allocations made inside AVNM are visible to it;
  a range someone typed into a tfvars file is not.

## What you need first

From the connectivity repo (`terraform output`):

| Output | Goes into | Notes |
|--------|-----------|-------|
| `ipam_region_pool_ids["<region>"]` | `ipam_pool_id` | the pool for the region the spoke is in |
| `virtual_hubs["<region>"].id` | `virtual_hub_id` | leave unset while `secured_vwan_enabled` is off |

If you have reader access to the connectivity state, read them directly instead of
copying strings:

```hcl
data "terraform_remote_state" "connectivity" {
  backend = "azurerm"
  config = {
    resource_group_name  = "rg-scandula-tfstate"
    storage_account_name = "<the state account>"
    container_name       = "tfstate"
    key                  = "connectivity.tfstate"
    use_azuread_auth     = true
  }
}

# ipam_pool_id   = data.terraform_remote_state.connectivity.outputs.ipam_region_pool_ids["eas"]
# virtual_hub_id = data.terraform_remote_state.connectivity.outputs.virtual_hubs["eas"].id
```

The pool and the hub live in the **connectivity subscription**, and the spoke usually
doesn't. The identity running this needs, in that subscription:

- on the IPAM pool (or the network manager): a role with
  `Microsoft.Network/networkManagers/ipamPools/*/action` and read — allocating is a write
  against the pool. `Network Contributor` at the pool's scope covers it.
- on the virtual hub: `Microsoft.Network/virtualHubs/*/action` and read, to create the
  connection. Not needed while `virtual_hub_id` is unset.

Ask the connectivity owners for those two role assignments, scoped to the pool and the
hub — not to the subscription.

## What it builds

| Resource | Name | Notes |
|----------|------|-------|
| Resource group | `rg-<name>` | |
| Virtual network | `vnet-<name>` | allocation of `vnet_address_count` addresses from the pool |
| Subnet | one per `subnets` key | each its own allocation from the same pool |
| Network security group | `nsg-<name>-<subnet>` | the flows named in `allow_inbound`, then a catch-all deny |
| NSG association | one per subnet | an unattached NSG blocks nothing |
| Hub connection | `conn-<name>` | only when `virtual_hub_id` is set |

## The NSG, and why the deny rule is there

Azure's own default rules allow **everything inbound from `VirtualNetwork`**. Left alone,
every spoke can reach every other spoke on every port, which is the flat network the whole
design is trying not to be. So each NSG here names its inbound flows and then denies the
rest of the network at priority 4000, above Azure's `AllowVnetInBound` (65000).

Sources are CIDRs (`/32` for a single host) **or** one Azure service tag per rule —
`AzureLoadBalancer`, `VirtualNetwork`, a regional tag. Not both in the same rule: azurerm
puts them in different attributes and refuses to mix them, so the example sorts them out
for you and a validation catches the mistake before Azure does.

Egress is not handled here at all. Routing intent at the hub sends this VNet's private
**and** internet traffic to the hub firewall, which
[allows nothing by default](../../docs/zero-trust.md). A new spoke therefore reaches
nothing until a flow is named in scandula's `east_west_flows` / `egress_*` — that's
deliberate, and it means a new spoke needs a PR against the connectivity repo before it
can talk to anything.

## Sizes

Sizes are addresses, not mask bits: `8` is a /29, `256` a /24, `1024` a /22. Ask for what
the spoke needs **plus room to grow** — growing later gets you a second, disjoint
allocation, not a bigger one.

## Run it

```bash
cp terraform.tfvars.example terraform.tfvars   # then edit it
terraform init
terraform plan
```

Tests run with no Azure credentials at all:

```bash
terraform init -backend=false && terraform test
```

From scandula's root, `make spoke-test` does the same, and `make mutants` includes this
root: every validation here has a rejection run that proves it.

## Not covered

- **Subnets Azure names for you** (`AzureBastionSubnet`, `GatewaySubnet`,
  `AzureFirewallSubnet`) and **delegated subnets** — both work with allocations, but the
  service usually dictates a minimum size.
- **Private DNS zone links**, which the connectivity core doesn't run yet
  ([docs/design.md](../../docs/design.md)).
- **Peering to another spoke.** Don't: traffic between spokes goes through the hub, so
  it's inspected. A peering is a hole around the firewall.
