locals {
  tags = merge({
    managed-by = "terraform"
    repo       = "benoitnvl/scandula"
  }, var.tags)

  # An empty scope means "the subscription Terraform is running against".
  scope_is_default       = length(var.network_manager_scope.management_group_ids) + length(var.network_manager_scope.subscription_ids) == 0
  scope_subscription_ids = local.scope_is_default ? [data.azurerm_subscription.current.id] : var.network_manager_scope.subscription_ids

  # The regions that get a secured hub: all of them, or none while the cost guard
  # (secured_vwan_enabled) is off.
  vwan_regions = var.secured_vwan_enabled ? var.regions : {}
}
