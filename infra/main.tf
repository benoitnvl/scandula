data "azurerm_subscription" "current" {}

# Control plane: the network manager and the root IPAM pool live here.
resource "azurerm_resource_group" "connectivity" {
  name     = "rg-${var.name_prefix}-connectivity"
  location = var.location
  tags     = local.tags
}

resource "azurerm_network_manager" "this" {
  name                = "avnm-${var.name_prefix}"
  location            = var.location
  resource_group_name = azurerm_resource_group.connectivity.name
  description         = "IPAM for the Azure hub network, managed from benoitnvl/scandula."
  scope_accesses      = var.scope_accesses
  tags                = local.tags

  scope {
    management_group_ids = length(var.network_manager_scope.management_group_ids) > 0 ? var.network_manager_scope.management_group_ids : null
    subscription_ids     = length(local.scope_subscription_ids) > 0 ? local.scope_subscription_ids : null
  }
}
