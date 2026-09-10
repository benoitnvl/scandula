# scandula

Terraform (HashiCorp, **not** OpenTofu) for the Azure connectivity core: regional hub
VNets whose address space comes from AVNM IPAM pools, plus AVNM connectivity
configurations and deployments. `README.md` has the layout, `docs/design.md` the
address plan. This file is what you need in order not to break things.

## ⚠ Most address-plan edits are destructive

- IPAM pool `name`, `location`, `parent_pool_name` and `address_prefixes` are **ForceNew**,
  and Azure won't delete a pool that still has allocations. A region key is identity:
  renaming `uks` replaces its pool, hub, subnets, config and deployment.
- `number_of_ip_addresses` (hub and subnets) can **grow but never shrink**.
- Read every plan for `must be replaced` on a pool, a hub VNet or the network manager,
  and stop if you see one you didn't intend.

## ⚠ Nothing in AVNM is live until it's deployed

A connectivity configuration does nothing until an `azurerm_network_manager_deployment`
commits it, and deployments are **per region**. Each region's deployment lists exactly
the configs committed there (its own hub-and-spoke, plus the hub mesh). Destroying a
deployment un-commits them and **removes the peerings AVNM made** in that region.

## Address space is never hardcoded

Hubs and hub subnets use `ip_address_pool { … }`, not `address_space` /
`address_prefixes`. Read what IPAM allocated from the `hub_vnets` output. The root pool
must never overlap `reserved_prefixes` (the homelab LAN, `10.1.0.0/23`) — a validation
enforces that.

## State, CI, and the one write path

- State lives in Azure Storage (`backend "azurerm" {}` + gitignored `infra/backend.hcl`),
  locked by blob lease — so unlike bonifaziu, a second checkout is not a second writer.
- CI (`runs-on: stazzona`) runs fmt, validate, test and trivy with `init -backend=false`,
  and **never authenticates to Azure**. `make plan` → `make apply` (which applies that
  saved plan) from a workstation is the only write path.
- `.terraform.lock.hcl` must be produced by **terraform** (`make lock`), never tofu — a
  tofu lock file records `registry.opentofu.org` and is useless here. It isn't committed
  yet: the first real `make init` should create it, and it lands in a PR.
- azurerm 5.x registers **no** resource providers by default; `Microsoft.Network` is
  registered once by hand (docs/bootstrap.md).

## Tests

`infra/tests/*.tftest.hcl` run against `mock_provider "azurerm"`, so `command = apply` is
safe and needs no credentials. Every validation in `variables.tf` has a rejection run;
**add one with every new validation**, and assert on anything whose wiring matters
(which pool a VNet allocates from, which configs a deployment commits).

**After touching `variables.tf`, run `make mutants`.** It disables each validation in turn
and demands a red run. A green suite is not enough: on day one it found three rejection
runs passing for the wrong reason, including one whose "outside the root" prefix
(`10.90.0.0/14`) was really being caught by the canonical-form check. It isn't in CI
because it runs the suite once per validation.

Mock gotchas that shape the test file:
- azurerm validates ID **format** even when mocked, so referenced types need realistic
  `mock_resource` ids (random 8-char strings fail).
- Mock ids are per resource *type*, and `override_resource` can't target an instance like
  `region["uks"]`. Per-region wiring is asserted through names and locations, and
  cross-resource wiring (root vs region pool, mesh vs hub-and-spoke) through
  resource-level overrides.
- tofu skips every run after a failed one, so one red run can hide others. `make mutants`
  accounts for that. Read raw `test` output with that in mind.

Locally `tofu test` works as a proxy when terraform isn't installed, but CI runs real
terraform — trust CI over the proxy.
