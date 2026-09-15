# The address authority: NetBox

**Decided 2026-09-15.** NetBox is the source of truth for **all** of Aberdeen's address
space. It replaces Microsoft's Azure IPAM in that role
([docs/azure-ipam-plan.md](azure-ipam-plan.md), superseded).

Nothing about the Azure side changes. AVNM still owns one delegated block and still
allocates inside it, Azure Policy still enforces that, and spokes still allocate from
AVNM pools ([examples/spoke](../examples/spoke)). What changes is the system holding
the plan above that block.

## The model

```
NetBox — the authority. Every range Aberdeen has, in one place.
 ├── on-premises ranges                  recorded here, denied in Azure by layer A
 ├── existing landing zones (no AVNM)    recorded here as they're discovered
 ├── other clouds, if any                recorded here
 └── one block delegated to AVNM         recorded here as a *container*
      └── AVNM IPAM (infra/ipam.tf)      allocates inside it — NetBox does not
           ├── region pools              one per region
           │    ├── hub reservations     static CIDRs
           │    └── spokes               ip_address_pool allocations
           └── root static CIDRs         things AVNM can't see
```

The delegated block is recorded in NetBox with status **container**, which in NetBox's
model means "the children of this range are managed elsewhere". That's the whole
contract: **nobody allocates inside AVNM's block from NetBox**, because NetBox can't
see what AVNM has already handed out, and AVNM can't see what NetBox would hand out.

## Why the change

| | Azure IPAM | NetBox |
|---|---|---|
| Installer | `deploy/deploy.ps1` (PowerShell + Bicep) only — [`azure-ipam/`](../azure-ipam) is our own reimplementation of it | official container images; this repo's [`netbox/platform`](../netbox/platform) is ordinary Azure plumbing around them |
| Terraform provider | none | [e-breuninger/netbox](https://registry.terraform.io/providers/e-breuninger/netbox/latest), maintained, 18M downloads |
| Asking it for a prefix | a `data "external"` block shelling out to `curl` — reserves during `plan`, never releases | `netbox_available_prefix`, a resource: in state, released on destroy |
| Releases | roughly one a year (v3.6.0, 2025-09-11) | steady; v4.7.0 in September 2026 |
| Upgrades | diff upstream's `deploy/` by hand each time | bump a digest and a provider version together |
| Models on-premises | barely | it's what the product is for |

The deciding one is the third row. An authority you can't query from Terraform isn't
an authority anyone will keep current by hand.

Layers A and B themselves are unchanged, and are still described where they were
written: [layer A](azure-ipam-plan.md#layer-a-on-premises-ranges-everywhere-from-day-one)
(deny on-premises ranges everywhere) and
[layer B](azure-ipam-plan.md#layer-b-avnm-only-allocation-per-migrated-scope) (require an
AVNM allocation, per migrated scope). Only the system above the delegated block changed.

## What was kept

- **AVNM allocates in Azure.** NetBox could allocate directly and hand the CIDR to
  `azurerm`, but NetBox can't *stop* anyone creating a VNet with a made-up range.
  Layer B ([infra/policy-avnm.tf](../infra/policy-avnm.tf)) can, because it checks for
  an AVNM allocation. Moving allocation to NetBox would trade the only enforcement we
  have for one less system.
- **`azure-ipam/` stays, dormant.** Nothing there was ever applied, so there's nothing
  to destroy. It remains the fallback until NetBox is live. Its deploy workflow must
  not be dispatched.

## Where it runs

Self-hosted on Azure Container Apps, in the same subscription as the rest —
[netbox/README.md](../netbox/README.md) has the shape, the cost (**about $60-100 a
month**, so it's off by default) and the one-time setup.

NetBox's own VNet takes an allocation from an AVNM region pool. That's deliberate:
the authority for the address plan doesn't get to write its own range down either.

## The two-sided version pin

NetBox breaks API compatibility in minor releases, and the provider only *warns* when
it meets a version it wasn't tested against. So both sides are pinned and moved
together:

- NetBox **v4.6.5**, by image digest, in `netbox/platform/release.json`
- the provider **~> 5.8**, whose tested ceiling is that version

v4.6.10 and v4.7.0 exist and are past the ceiling. Don't take them until the provider's
table moves.

⚠ Provider **6.0.0 will be mostly auto-generated** rather than hand-maintained
(announced in the 5.8.0 release notes). Treat that as a migration, not a bump.

## What has to happen, in order

1. **A paid subscription.** Not the Visual Studio credit one: NetBox runs continuously
   and would exhaust it, and Azure then disables the subscription — the tfstate account
   with it. `netbox/platform` refuses a credit subscription unless told twice.
2. **Build it** (`make netbox-*`), create the first user, make an API token.
3. **Record what exists**: on-premises ranges first, because they're the ones nothing
   in Azure can see. `records`' `reserved_prefixes` output is exactly the shape
   `infra`'s `reserved_prefixes` variable takes.
4. **Check `10.64.0.0/12`.** It's still a placeholder in both repositories. Once the
   real landing-zone and on-premises ranges are in NetBox, the overlap validation in
   `records` is what proves the delegated block is safe to apply.
5. **Turn layer A on in Audit** with those ranges, review the findings, then Deny.
6. **Then** the guardrail policies of [zero-trust.md](zero-trust.md) step 3.

## Open questions for Aberdeen

- The on-premises RFC 1918 ranges. Everything above waits on this list.
- The landing-zone VNet ranges, to replace `10.64.0.0/12`.
- Who runs NetBox day to day, and who gets an account — it becomes the place the
  address plan is decided, not just recorded.
- Whether NetBox should authenticate against Entra ID (it supports OIDC) rather than
  keeping local accounts.
