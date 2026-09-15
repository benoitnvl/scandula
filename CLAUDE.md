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

## ⚠ The address authority is NetBox, not this repo

Decided 2026-09-15 (`docs/netbox-plan.md`), replacing Azure IPAM. NetBox is the source of
truth for **all** of Aberdeen's address space: the existing Enterprise-Scale landing zones
(no AVNM), the on-premises RFC 1918 ranges, and **one block delegated to AVNM**, which is this
repo's `ipam_root_prefix`. Workloads move under AVNM piece by piece.

**The Azure side did not change.** AVNM still allocates inside the delegated block, layers A
and B still enforce it, spokes still allocate from AVNM pools. NetBox replaced only the system
above that block — because it can be queried from Terraform and Azure IPAM can't.

- `10.64.0.0/12` is a **placeholder**. Don't apply until it's checked against the landing-zone
  and on-premises ranges.
- *Reserved* (IPAM, `reserved_prefixes`) isn't *blocked*. Blocking needs Azure Policy: layer A
  denies on-premises ranges everywhere, and layer B enforces AVNM allocation per migrated scope
  only.
- Never allocate inside AVNM's block from NetBox. AVNM can't see those allocations, and
  NetBox can't see AVNM's. The block is recorded in NetBox with status **container** for
  exactly this reason — keep it that way.
- **Layer A is `infra/policy-onprem.tf`**, off until `onprem_policy.management_group_id` is
  set. It reaches every VNet under that management group, far beyond this repo, so never
  set it without the user saying so. Move Audit → Deny only after its findings are reviewed.
  **Keep the same-family `if()` guard** in its rule: `ipRangeContains` fails on mixed
  address families, and a failed evaluation is a deny even under Audit. Without the guard,
  every dual-stack VNet is blocked.
- **Layer B is `infra/policy-avnm.tf`**, off until `avnm_allocation_policy.management_group_id`
  is set. Add an assignment only for a scope that has fully migrated, never the landing-zone
  root while VNets outside AVNM live under it, and only with the user's say-so.
  **Keep the count expressions:** Microsoft's sample uses bare `[*]` conditions, which are true
  over an empty array, so it lets through a VNet with no allocation at all.

NetBox is self-hosted on Azure by two Terraform roots in `netbox/` (runbook in its README):

- `netbox/platform` runs NetBox itself — Container Apps (web, rqworker, a housekeeping job),
  PostgreSQL Flexible Server, Azure Cache for Redis, Key Vault, an Azure Files share. **Off
  until `netbox_enabled = true`**: about **$60-100/month**, continuously. It refuses credit
  subscriptions. `tests/` asserts that off plans nothing billable. Applied from a workstation
  (`make netbox-plan` → `make netbox-apply`), not by CI.
- `netbox/records` is the address plan as data through the NetBox API. Its URL and token come
  from `NETBOX_SERVER_URL` / `NETBOX_API_TOKEN` in the environment — **never** a tfvars file.
- **The version pin has two sides.** NetBox **v4.6.5** (by image digest in
  `netbox/platform/release.json`) and provider **~> 5.8**, because 4.6.5 is the newest NetBox
  that provider is tested against. v4.6.10 and v4.7.0 exist and are past the ceiling; NetBox
  breaks its API in minor releases and the provider only *warns*. Move both together, in a PR.
  Provider 6.0.0 will be auto-generated — a migration, not a bump.
- **NetBox's own VNet allocates from AVNM.** The authority for the address plan doesn't get to
  write its own range down either. Keep it that way.
- **Public ingress with a mandatory allow-list.** `public_ingress = true` and an empty
  `allowed_source_cidrs` is refused by a precondition. It's public only because there's no VPN
  or ExpressRoute gateway yet; switch to internal once there is.
- `make netbox-test` after changing either root; `make mutants` after touching a `variables.tf`.

⚠ **`azure-ipam/` is DORMANT** (since 2026-09-15) and was **never applied** — there is nothing
deployed and nothing to destroy. It stays as the fallback until NetBox is live. **Don't dispatch
`azure-ipam-deploy.yaml`**, and don't create the OIDC identities or state containers it wants.
If NetBox sticks, delete the directory, the workflow and those identities. The rules below apply
only if it is ever revived:

- `azure-ipam/entra` is part 1 (the Entra ID objects) and `azure-ipam/platform` is part 2 (the
  Azure resources). **Both are applied only by `.github/workflows/azure-ipam-deploy.yaml`**,
  each as its own OIDC workload identity. There are no local apply targets. **Each part's state
  has its own container** (`tfstate-azure-ipam-entra` and `-platform`), writable only by that
  part's identity. The platform identity may also read part 1's, and the entra identity gets
  nothing on part 2's, because that state holds the engine secret. Don't add a local apply
  path back, and don't merge the containers.
- Part 1 makes part 2's identity an owner of both apps, so part 2 creates the engine secret
  itself. **No secret is ever handed over.** Don't reintroduce a hand-over.
- **An apply runs only with the digest of a reviewed plan** (`reviewed_digest`), because
  GitHub environments aren't available to private repos on GitHub Free. Keep that gate.
- **Azure trusts only tokens from `azure-ipam-deploy.yaml` run from `main`**: the repo's OIDC
  subject includes `job_workflow_ref`, and the federated credentials pin that file. Never
  reset the subject template or loosen the credentials to the branch alone. `claude.yaml`
  mints tokens from `main` too, and the entra identity holds Graph `Directory.ReadWrite.All`.
- **The pin is `azure-ipam/platform/release.json`** (release, commit, zip SHA-256, Python).
  Change it all together, in a PR. Terraform refuses a zip whose SHA-256 differs.
- **Keep run-from-package** (`WEBSITE_RUN_FROM_PACKAGE=1`). An Oryx build
  (`SCM_DO_BUILD_DURING_DEPLOYMENT`) installs the engine's unpinned `requirements.txt`, and the
  container install runs `ipam:latest`: both ignore the pin.
- **Part 2 is cost-guarded** (`ipam_enabled`, off by default) and refuses credit subscriptions.
  Don't weaken either. **Part 2's state holds the engine secret.**
- The roots mirror Azure/ipam v3.6.0's `deploy.ps1` and Bicep. On an upgrade, diff upstream's
  `deploy/` between the two releases for new settings, roles or permissions, not just the zip.
- Changed either root or `azure-ipam/ci.sh`? `make ipam-test` (both roots and the script), and
  `make mutants` after touching a `variables.tf`. Changed a workflow? `actionlint`.

## Connectivity is Virtual WAN's, not AVNM's

Standard vWAN meshes its hubs itself, and spokes attach with
`azurerm_virtual_hub_connection` from the repos that own them. AVNM can't do this job
here: a vWAN hub can't join a network group, and an AVNM hub-and-spoke config with a vWAN
hub is preview and needs a vWAN connection policy that azurerm 5.4 can't set. Routing
intent sends private **and** internet traffic through each hub's firewall. The shared
policy allows **nothing by default** (`firewall-rules.tf`, since 2026-09-14): every flow and
destination is named in `east_west_flows` / `egress_https_fqdns` / `egress_http_fqdns` /
`egress_fqdn_tags`, validations refuse `"Any"` protocols, `"*"` ports and a bare `*` FQDN, and
`rcg-baseline` isn't created while nothing is named. **Never reintroduce a blanket rule**: add
a named entry, with who asked in its description. The firewalls' logs go to `log-<prefix>-hub`
(`diagnostics.tf`); keep them on, because nothing else shows what the rules did. The target and
what's still missing: `docs/zero-trust.md`.

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
