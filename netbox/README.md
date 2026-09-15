# NetBox — the address authority

NetBox ([netbox-community/netbox](https://github.com/netbox-community/netbox)) holds
Aberdeen's whole address plan: the existing landing zones, the on-premises ranges,
anything in another cloud, and **one block delegated to AVNM**, which is the
connectivity repo's `ipam_root_prefix`. Inside that block AVNM allocates; everywhere
else NetBox is the record. The reasoning is in
[docs/netbox-plan.md](../docs/netbox-plan.md).

Two Terraform roots:

| Root | Provider | What it is |
|------|----------|------------|
| [`platform/`](platform) | azurerm | NetBox itself, running on Azure Container Apps. Off until `netbox_enabled = true` — it costs money |
| [`records/`](records) | e-breuninger/netbox | The address plan as data: aggregates, the delegated block, the on-premises ranges |

`platform` builds the thing; `records` fills it in. They're separate because they need
different credentials (Azure vs a NetBox API token) and move at different speeds — the
platform changes on upgrades, the records change whenever the plan does.

## Why NetBox and not Azure IPAM

Microsoft's Azure IPAM was the authority until 2026-09-15
([docs/azure-ipam-plan.md](../docs/azure-ipam-plan.md), superseded). It ships no
Terraform installer at all — only `deploy/deploy.ps1` — so the roots in
[`azure-ipam/`](../azure-ipam) are a hand-written reimplementation of its PowerShell
and Bicep, carrying a diff-upstream-by-hand cost on every upgrade. It also has no
Terraform provider, so the only way to ask it for a prefix is a `data "external"`
block shelling out to `curl`, which reserves during `plan` and never releases.

NetBox is a supported product with a maintained Terraform provider, it models
on-premises and other clouds properly, and `netbox_available_prefix` is a real
resource: allocations land in state and are released on destroy.

`azure-ipam/` is kept **dormant**, not deleted — nothing there was ever applied, and
it stays as the fallback until NetBox is live. Don't dispatch its workflow.

## Cost

Retail prices, East Asia, fetched 2026-09-15. The whole thing is off until
`netbox_enabled = true`, and `tests/` asserts that off plans nothing billable.

| Component | Rate | Per month (730 h) |
|-----------|------|-------------------|
| Container Apps — web, 0.5 vCPU / 1 GiB, 1 replica | vCPU $0.000024/s active, $0.000003/s idle; memory $0.000003/GiB-s | **$12** idle → **$39** busy |
| Container Apps — worker, 0.25 vCPU / 0.5 GiB | same | **$6** idle → **$20** busy |
| PostgreSQL Flexible Server, B1ms | $0.0286/h | **$20.88** |
| PostgreSQL storage, 32 GiB | $0.15/GB/month | **$4.80** |
| Azure Cache for Redis, Basic C0 | $0.022/h | **$16.06** |
| Azure Files, media share | $0.06/GB/month | **~$1** |
| Log Analytics | per GB ingested | a few dollars at this volume |
| | | **≈ $60 quiet, ≈ $100 busy** |

Container Apps bills the *idle* rate while a replica is running but serving nothing,
which is what NetBox does most of the day — hence the range. Azure's monthly free
grant for Container Apps offsets part of the compute; the table ignores it.

⚠ **Not on the Visual Studio credit subscription.** NetBox runs continuously, the
credit runs out, and Azure then disables the subscription — the tfstate account with
it. `platform` refuses a credit or trial subscription unless
`allow_credit_subscription = true`.

## What platform/ builds

The shape netbox-docker runs, with Azure's managed services in place of its containers:

| netbox-docker | Here |
|---------------|------|
| `netbox` (web) | Container App `ca-<prefix>-netbox`, ingress on 8080 |
| `netbox-worker` | Container App `ca-<prefix>-netbox-worker`, `manage.py rqworker`, no ingress |
| `housekeeping` cron | Container Apps Job `caj-<prefix>-netbox-housekeeping`, daily at 01:00 |
| `postgres` | PostgreSQL Flexible Server, injected into a delegated subnet |
| `redis` + `redis-cache` | One Azure Cache for Redis; queue on database 0, cache on database 1 |
| the media/reports/scripts volumes | An Azure Files share, mounted in both containers |

Plus a VNet **allocated from AVNM** — NetBox is the authority for the plan and still
doesn't get to write its own range down — a Key Vault holding the database password,
the Redis key and Django's `SECRET_KEY`, and a Log Analytics workspace.

The image is pinned **by digest** in [`platform/release.json`](platform/release.json),
not by tag.

## ⚠ The version pin has two sides

| | Pinned to | Why |
|---|---|---|
| NetBox | **v4.6.5** | the newest release the Terraform provider is tested against |
| Provider | **~> 5.8** | current; its table stops at NetBox 4.6.5 |

NetBox v4.6.10 and v4.7.0 exist. They are **past the provider's tested ceiling**, and
NetBox breaks API compatibility in minor releases — the provider only prints a
non-blocking warning when it probes a version it doesn't know. Bump the two together,
after checking [the provider's compatibility table](https://github.com/e-breuninger/terraform-provider-netbox#supported-netbox-versions),
and change `netbox_version`, `image_digest` and the provider constraint in one PR.

Resolve a digest for a new version with:

```bash
crane digest netboxcommunity/netbox:v4.6.5
```

## One-time setup

Neither root is applied by CI. Both are `make` targets run from a workstation against
a paid subscription.

1. **Two state containers**, `tfstate-netbox-platform` and `tfstate-netbox-records`,
   in the existing state account. Copy each `backend.hcl.example` to `backend.hcl`
   and fill it in.
   ⚠ `platform`'s state holds the database password, the Redis key and `SECRET_KEY`.
2. **Register the resource providers** the platform needs, once, in the target
   subscription: `Microsoft.App`, `Microsoft.DBforPostgreSQL`, `Microsoft.Cache`,
   `Microsoft.KeyVault`, `Microsoft.OperationalInsights`, `Microsoft.Storage`.
   azurerm 5.x registers nothing by itself (docs/bootstrap.md).
3. **Build it:** set `ipam_pool_id` (from the connectivity repo's
   `ipam_region_pool_ids`) and `allowed_source_cidrs`, then
   `make netbox-init && make netbox-plan`, read the plan, `make netbox-apply`.
4. **Create the first user**, which nothing automates because it needs a password
   you choose:

   ```bash
   az containerapp exec -n ca-scandula-netbox -g rg-scandula-netbox \
     --command "/opt/netbox/venv/bin/python /opt/netbox/netbox/manage.py createsuperuser"
   ```

5. **Make an API token** in the NetBox UI (Admin → API Tokens), then:

   ```bash
   export NETBOX_SERVER_URL="$(terraform -chdir=netbox/platform output -raw netbox_url)"
   export NETBOX_API_TOKEN="<the token>"   # never committed, never in tfvars
   make netbox-records-init && make netbox-records-plan
   ```

6. **Record what already exists**: the on-premises ranges and the landing-zone ranges,
   in `records/terraform.tfvars`. That list is also what `infra`'s `reserved_prefixes`
   should hold — the `reserved_prefixes` output of `records` is in exactly that shape.

## Known gaps

- **No NSGs on NetBox's subnets.** The Container Apps infrastructure subnet has its
  own required flows and a wrong rule there breaks the environment in ways that are
  hard to read. The guardrail policy that will require NSGs everywhere
  ([docs/zero-trust.md](../docs/zero-trust.md), step 3) isn't assigned yet; fix this
  before it is.
- **Public ingress.** There's no VPN or ExpressRoute gateway in the hubs yet, so an
  internal-only NetBox would be unreachable by people. It's public with a mandatory
  source allow-list — `public_ingress = true` with an empty `allowed_source_cidrs` is
  refused. Set `public_ingress = false` once a gateway exists.
- **No hub connection.** NetBox's VNet holds an allocation but isn't attached to a
  hub; attach it from the connectivity repo when the hubs are on.
- **No SSO.** Local accounts only. NetBox supports OIDC against Entra ID
  (`REMOTE_AUTH_BACKEND`), which is the obvious follow-up.
- **The delegated prefix lives in two places** — `infra`'s `ipam_root_prefix` and
  `records`' `avnm_delegated_prefix`. Both validate it, neither reads the other.
