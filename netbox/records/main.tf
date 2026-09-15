# Aberdeen's address plan, as NetBox records it.
#
# NetBox is the authority: it holds everything, including the ranges Azure can't see
# (on-premises, other clouds). It delegates exactly one block to AVNM, and inside
# that block AVNM does the allocating — see docs/netbox-plan.md. That's why the
# delegated block is recorded as a *container* here: a container is a range whose
# children are managed elsewhere, so nobody opens NetBox and hands out a piece of it.
#
# Nothing in this root talks to Azure, and nothing in the connectivity repo talks to
# NetBox. The link between them is one number written down twice: the delegated
# prefix here, and infra's ipam_root_prefix there. Each side validates its own copy
# — that it's canonical, inside its aggregate, not overlapping anything it knows
# about — but neither reads the other, so keeping the two equal is a human job.

resource "netbox_rir" "this" {
  for_each = var.rirs

  name        = each.key
  description = each.value
}

resource "netbox_aggregate" "this" {
  for_each = var.aggregates

  prefix      = each.value.prefix
  rir_id      = netbox_rir.this[each.value.rir].id
  description = each.value.description
  tags        = var.default_tags
}

# The one block AVNM owns. Status "container": its children live in AVNM's pools,
# not here.
resource "netbox_prefix" "avnm_delegated" {
  prefix      = var.avnm_delegated_prefix
  status      = "container"
  description = "Delegated to AVNM (benoitnvl/scandula, infra/ipam.tf ipam_root_prefix). Allocations inside this block are made by AVNM IPAM, never here."
  tags        = var.default_tags

  depends_on = [netbox_aggregate.this]
}

# The region pools inside it, recorded so the plan reads correctly in NetBox. Also
# containers: AVNM allocates from them.
resource "netbox_prefix" "avnm_region" {
  for_each = var.avnm_region_prefixes

  prefix      = each.value
  status      = "container"
  description = "AVNM region pool '${each.key}'. Spokes allocate from it through AVNM, not here."
  tags        = var.default_tags

  depends_on = [netbox_prefix.avnm_delegated]
}

# Everything outside Azure. These are the ranges layer A denies inside Azure
# (infra/policy-onprem.tf), which is only as good as this list.
resource "netbox_prefix" "onprem" {
  for_each = var.onprem_prefixes

  prefix      = each.value.prefix
  status      = each.value.status
  description = each.value.description
  tags        = var.default_tags

  depends_on = [netbox_aggregate.this]
}
