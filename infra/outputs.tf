output "network_manager_id" {
  description = "The AVNM instance. The IPAM pools live under it."
  value       = azurerm_network_manager.this.id
}

output "ipam_root_pool_id" {
  description = "The root IPAM pool."
  value       = azurerm_network_manager_ipam_pool.root.id
}

output "ipam_region_pool_ids" {
  description = "Region => IPAM pool id. Spokes allocate their address space from their region's pool."
  value       = { for k, p in azurerm_network_manager_ipam_pool.region : k => p.id }
}

output "hub_address_prefixes" {
  description = "Region => the range reserved for that region's vWAN hub (reserved even while the hubs are off)."
  value       = { for k, r in var.regions : k => r.hub_address_prefix }
}

output "secured_vwan_enabled" {
  description = "Whether the (costly) secured Virtual WAN is built."
  value       = var.secured_vwan_enabled
}

output "virtual_wan_id" {
  description = "The Virtual WAN, or null while secured_vwan_enabled is off."
  value       = one(azurerm_virtual_wan.this[*].id)
}

output "virtual_hubs" {
  description = "Region => secured hub. Spokes attach with azurerm_virtual_hub_connection to `id`. Empty while secured_vwan_enabled is off."
  value = { for k, h in azurerm_virtual_hub.this : k => {
    id                  = h.id
    name                = h.name
    location            = h.location
    address_prefix      = h.address_prefix
    firewall_id         = azurerm_firewall.hub[k].id
    firewall_private_ip = one(azurerm_firewall.hub[k].virtual_hub).private_ip_address
    firewall_public_ips = one(azurerm_firewall.hub[k].virtual_hub).public_ip_addresses
  } }
}

output "firewall_policy_id" {
  description = "The policy shared by every hub firewall — add rule collection groups to it. Null while off."
  value       = one(azurerm_firewall_policy.this[*].id)
}

output "onprem_policy_assignment_id" {
  description = "The assignment of the on-premises overlap policy. Null while onprem_policy.management_group_id is unset."
  value       = one(azurerm_management_group_policy_assignment.onprem_overlap[*].id)
}

output "avnm_allocation_policy_definition_id" {
  description = "The AVNM allocation policy's definition. Null while avnm_allocation_policy.management_group_id is unset."
  value       = one(azurerm_policy_definition.avnm_allocation[*].id)
}

output "avnm_allocation_policy_assignment_ids" {
  description = "Assignment key => assignment id, one per migrated scope."
  value = merge(
    { for k, a in azurerm_management_group_policy_assignment.avnm_allocation : k => a.id },
    { for k, a in azurerm_subscription_policy_assignment.avnm_allocation : k => a.id },
  )
}

output "firewall_log_analytics_workspace_id" {
  description = "Where the hub firewalls send their logs. Null while the hubs are off or firewall_diagnostics_enabled is false."
  value       = one(azurerm_log_analytics_workspace.hub[*].id)
}

output "firewall_rules_named" {
  description = "What the hub firewall allows: east-west flow names, and the count of egress destinations. Empty means deny-all."
  value = {
    east_west_flows     = keys(var.east_west_flows)
    egress_destinations = local.egress_destinations
  }
}
