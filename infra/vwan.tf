# Secured Virtual WAN: one Standard hub per region, an Azure Firewall in each, and
# routing intent sending both private and internet traffic through that firewall.
#
# Everything here is gated on secured_vwan_enabled (default false) — see its
# description for what it costs. With it off, this file plans nothing.
#
# Why Virtual WAN does the hub-to-hub and hub-to-spoke work, not AVNM: a vWAN hub
# can't join an AVNM network group, and using one as the hub of an AVNM
# hub-and-spoke config is preview and needs a vWAN "connection policy" that azurerm
# 5.4 can't set. Standard vWAN meshes its own hubs; spokes attach with
# azurerm_virtual_hub_connection from the repos that own them.
#
# ⚠ A hub's address_prefix, location and virtual_wan_id are ForceNew. Replacing a
# hub drops every spoke connection to it.

resource "azurerm_resource_group" "vwan" {
  count = var.secured_vwan_enabled ? 1 : 0

  name     = "rg-${var.name_prefix}-vwan"
  location = var.location
  tags     = local.tags
}

resource "azurerm_virtual_wan" "this" {
  count = var.secured_vwan_enabled ? 1 : 0

  name                = "vwan-${var.name_prefix}"
  resource_group_name = azurerm_resource_group.vwan[0].name
  location            = var.location
  # Basic vWAN is site-to-site VPN only: no Azure Firewall, no inter-hub transit.
  type = "Standard"
  tags = local.tags
}

resource "azurerm_virtual_hub" "this" {
  for_each = local.vwan_regions

  name                = "vhub-${var.name_prefix}-${each.key}"
  resource_group_name = azurerm_resource_group.vwan[0].name
  location            = each.value.location
  virtual_wan_id      = azurerm_virtual_wan.this[0].id
  sku                 = "Standard"
  address_prefix      = each.value.hub_address_prefix
  tags                = local.tags

  # The reservation must exist before the hub claims the range.
  depends_on = [azurerm_network_manager_ipam_pool_static_cidr.hub]
}

# One policy for every hub. Its rules are in firewall-rules.tf; anything they don't
# allow is denied, because Azure Firewall denies by default.
resource "azurerm_firewall_policy" "this" {
  count = var.secured_vwan_enabled ? 1 : 0

  name                = "afwp-${var.name_prefix}"
  resource_group_name = azurerm_resource_group.vwan[0].name
  location            = var.location
  sku                 = var.firewall_sku_tier
  tags                = local.tags
}

resource "azurerm_firewall" "hub" {
  for_each = local.vwan_regions

  name                = "afw-${var.name_prefix}-${each.key}"
  resource_group_name = azurerm_resource_group.vwan[0].name
  location            = each.value.location
  sku_name            = "AZFW_Hub"
  sku_tier            = var.firewall_sku_tier
  firewall_policy_id  = azurerm_firewall_policy.this[0].id
  tags                = local.tags

  virtual_hub {
    virtual_hub_id  = azurerm_virtual_hub.this[each.key].id
    public_ip_count = 1
  }
}

resource "azurerm_virtual_hub_routing_intent" "this" {
  for_each = local.vwan_regions

  name           = "ri-${var.name_prefix}-${each.key}"
  virtual_hub_id = azurerm_virtual_hub.this[each.key].id

  routing_policy {
    name         = "InternetTrafficPolicy"
    destinations = ["Internet"]
    next_hop     = azurerm_firewall.hub[each.key].id
  }

  # Also covers hub-to-hub: with private routing intent on both hubs, inter-hub
  # traffic crosses both firewalls.
  routing_policy {
    name         = "PrivateTrafficPolicy"
    destinations = ["PrivateTraffic"]
    next_hop     = azurerm_firewall.hub[each.key].id
  }
}
