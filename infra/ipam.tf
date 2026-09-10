# root pool (ipam_root_prefix, in var.location)
#  ├── one child pool per region (regions[*].address_prefix, in that region)
#  │     ├── hub reservation — the vWAN hub's hub_address_prefix, as a static CIDR
#  │     └── spokes          — allocated by the repos that own them, not here
#  └── static CIDRs          — reserved for things AVNM can't see (root_static_cidrs)
#
# The hub reservations exist whether or not secured_vwan_enabled is on: the address
# plan shouldn't change shape when the (expensive) hubs are switched on.
#
# ⚠ Pool name, location, parent and prefixes are all ForceNew, and a pool with
# allocations can't be deleted. Treat any "must be replaced" on a pool in a plan
# as a stop sign.

resource "azurerm_network_manager_ipam_pool" "root" {
  name               = "ipam-${var.name_prefix}-root"
  location           = var.location
  network_manager_id = azurerm_network_manager.this.id
  display_name       = "root"
  description        = "All Azure address space handed out by scandula. Region pools are carved from here."
  address_prefixes   = [var.ipam_root_prefix]
  tags               = local.tags
}

resource "azurerm_network_manager_ipam_pool" "region" {
  for_each = var.regions

  name               = "ipam-${var.name_prefix}-${each.key}"
  location           = each.value.location
  network_manager_id = azurerm_network_manager.this.id
  parent_pool_name   = azurerm_network_manager_ipam_pool.root.name
  display_name       = each.key
  description        = "The vWAN hub and the spokes in ${each.value.location}."
  address_prefixes   = [each.value.address_prefix]
  tags               = local.tags
}

# A Virtual WAN hub isn't a VNet, so it can't take an IPAM allocation. Reserve its
# range in the region pool so IPAM never hands it to a spoke.
resource "azurerm_network_manager_ipam_pool_static_cidr" "hub" {
  for_each = var.regions

  name             = "vhub-${each.key}"
  ipam_pool_id     = azurerm_network_manager_ipam_pool.region[each.key].id
  address_prefixes = [each.value.hub_address_prefix]
}

resource "azurerm_network_manager_ipam_pool_static_cidr" "root" {
  for_each = var.root_static_cidrs

  name             = each.key
  ipam_pool_id     = azurerm_network_manager_ipam_pool.root.id
  address_prefixes = each.value
}
