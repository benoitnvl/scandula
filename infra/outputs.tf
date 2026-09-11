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
