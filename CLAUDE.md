# scandula

Terraform (HashiCorp, **not** OpenTofu) for the Azure connectivity core: a secured
Virtual WAN (Standard hub + Azure Firewall + routing intent per region), with the
address plan in AVNM IPAM pools. `README.md` has the layout, `docs/design.md` the
topology, address plan and cost. This file is what you need in order not to break
things.

**This is an Aberdeen project, not part of the benoitnvl homelab estate.** Don't link it
to the estate: no homelab ranges, no `mocridhe.co.uk` DNS, no estate repos or docs. The
repo lives under benoitnvl, which is the only reason stazzona comes up at all (see CI
below).

## ⚠ The secured vWAN costs real money, so it's off by default

`secured_vwan_enabled` defaults to **false**, and `tests/` asserts that nothing billable
by the hour is planned while it's off. Each secured hub is about **$470/month** (Standard
hub $0.25/h + Firewall Basic in a hub $0.395/h, retail prices 2026-09-10), and the price
is the same in every commercial region. The bootstrap subscription is a **Visual Studio
credit** subscription with a spending limit: two hubs would burn through the credit in
under two days, and then Azure **disables the subscription, tfstate account included**.
Never flip the flag there, and never flip it without the user saying so.

The hubs are in **East Asia + Southeast Asia**, and the control plane is in East Asia.
That was the user's choice, to avoid capacity contention: UK South lists **no VM sizes at
all** for this subscription. The tfstate account stays in UK South. Evidence and a
fallback (Korea Central) are in `docs/design.md#regions`.

## ⚠ Most address-plan edits are destructive

- IPAM pool `name`, `location`, `parent_pool_name` and `address_prefixes` are **ForceNew**,
  and Azure won't delete a pool that still has allocations. A region key is identity:
  renaming `uks` replaces its pool, its hub reservation, and its hub.
- A virtual hub's `address_prefix`, `location` and `virtual_wan_id` are ForceNew, and
  replacing a hub **drops every spoke connection to it**.
- Read every plan for `must be replaced` on a pool, a hub, a firewall or the network
  manager, and stop if you see one you didn't intend.

## Hub ranges are explicit, but IPAM still owns them

A vWAN hub isn't a VNet, so it can't take an `ip_address_pool` allocation. Each region's
`hub_address_prefix` is written in tfvars and **reserved as a static CIDR** in that
region's pool (always, even with the hubs off), so IPAM never hands it to a spoke.
Validations keep it canonical, /24 or larger, and inside its own region pool. The root
pool must never overlap `reserved_prefixes`: on-premises ranges, empty until someone sets
them.

## Connectivity is Virtual WAN's, not AVNM's

Standard vWAN meshes its hubs itself, and spokes attach with
`azurerm_virtual_hub_connection` from the repos that own them. AVNM can't do this job
here: a vWAN hub can't join a network group, and an AVNM hub-and-spoke config with a vWAN
hub is preview and needs a vWAN connection policy that azurerm 5.4 can't set. Routing
intent sends private **and** internet traffic through each hub's firewall. The shared
policy has no rules yet, so everything crossing a hub is denied until rules are added.

## State, CI, and the one write path

- State lives in Azure Storage (`backend "azurerm" {}` + gitignored `infra/backend.hcl`),
  locked by blob lease, so a second checkout is not a second writer.
- CI runs fmt, validate, test and trivy with `init -backend=false`, and **never
  authenticates to Azure**. It's on GitHub-hosted `ubuntu-latest`, **not stazzona**:
  benoitnvl is a user account, so self-hosted runners are per-repo, and stazzona has no
  scale set for scandula. `runs-on: stazzona` queues forever; PR #1 found that out.
- `make plan` → `make apply` (which applies that saved plan) from a workstation is the
  only write path.
- `infra/.terraform.lock.hcl` is committed. Regenerate it with `make lock`, only ever with
  **terraform**: a tofu lock file records `registry.opentofu.org` and is useless here.
- azurerm 5.x registers **no** resource providers by default. `Microsoft.Network`
  (Terraform) and `Microsoft.Storage` (the state account) are registered once by hand;
  see docs/bootstrap.md, which also records what the first bootstrap tripped over.

## Tests

`infra/tests/*.tftest.hcl` run against `mock_provider "azurerm"`, so `command = apply` is
safe and needs no credentials. Every validation in `variables.tf` has a rejection run;
**add one with every new validation**, and assert on anything whose wiring matters
(which pool a hub range is reserved on, which firewall a hub's routing intent points at,
and that the cost guard really plans nothing).

**After touching `variables.tf`, run `make mutants`.** It disables each validation in turn
and demands a red run. A green suite is not enough: on day one it found three rejection
runs passing for the wrong reason, including one whose "outside the root" prefix
(`10.90.0.0/14`) was really being caught by the canonical-form check. It isn't in CI
because it runs the suite once per validation.

Mock gotchas that shape the test file:
- azurerm validates ID **format** even when mocked, so referenced types need realistic
  `mock_resource` ids (random 8-char strings fail).
- Mock ids are per resource *type*, and `override_resource` can't target an instance like
  `region["uks"]`. Per-region wiring is asserted through names, locations and prefixes,
  and cross-resource wiring (root vs region pool) through resource-level overrides.
- tofu skips every run after a failed one, so one red run can hide others. `make mutants`
  accounts for that. Read raw `test` output with that in mind.

Locally `tofu test` works as a proxy when terraform isn't installed, but CI runs real
terraform — trust CI over the proxy.
