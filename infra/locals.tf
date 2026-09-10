locals {
  tags = merge({
    managed-by = "terraform"
    repo       = "benoitnvl/scandula"
  }, var.tags)

  # An empty scope means "the subscription Terraform is running against".
  scope_is_default       = length(var.network_manager_scope.management_group_ids) + length(var.network_manager_scope.subscription_ids) == 0
  scope_subscription_ids = local.scope_is_default ? [data.azurerm_subscription.current.id] : var.network_manager_scope.subscription_ids

  # Hubs are meshed to each other only when there's more than one of them.
  hub_mesh = length(var.regions) > 1

  # "<region>.<subnet name>" => one azurerm_subnet per hub subnet.
  hub_subnets = merge([for rk, r in var.regions : {
    for name, size in r.hub_subnets : "${rk}.${name}" => { region = rk, name = name, size = size }
  }]...)
}
