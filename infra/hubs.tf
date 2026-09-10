# No address space is written down here. Each hub asks its region pool for
# hub_ip_count addresses and IPAM picks the block; subnets do the same inside it.
# Read the result back from the hub_vnets output.
#
# ⚠ number_of_ip_addresses can grow but never shrink (Azure refuses).

resource "azurerm_virtual_network" "hub" {
  for_each = var.regions

  name                = "vnet-${var.name_prefix}-hub-${each.key}"
  location            = each.value.location
  resource_group_name = azurerm_resource_group.hub[each.key].name
  tags                = local.tags

  ip_address_pool {
    id                     = azurerm_network_manager_ipam_pool.region[each.key].id
    number_of_ip_addresses = tostring(each.value.hub_ip_count)
  }
}

resource "azurerm_subnet" "hub" {
  for_each = local.hub_subnets

  name                 = each.value.name
  resource_group_name  = azurerm_resource_group.hub[each.value.region].name
  virtual_network_name = azurerm_virtual_network.hub[each.value.region].name

  ip_address_pool {
    id                     = azurerm_network_manager_ipam_pool.region[each.value.region].id
    number_of_ip_addresses = tostring(each.value.size)
  }
}
