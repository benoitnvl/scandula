output "network_manager_id" {
  description = "The AVNM instance. Network groups and IPAM pools live under it."
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

output "hub_vnets" {
  description = "Region => hub VNet, including the prefixes IPAM actually allocated to it."
  value = { for k, v in azurerm_virtual_network.hub : k => {
    id                  = v.id
    name                = v.name
    resource_group_name = v.resource_group_name
    location            = v.location
    address_prefixes    = one(v.ip_address_pool).allocated_ip_address_prefixes
  } }
}

output "hub_subnet_ids" {
  description = "\"<region>.<subnet>\" => subnet id (GatewaySubnet, AzureFirewallSubnet, …)."
  value       = { for k, s in azurerm_subnet.hub : k => s.id }
}

output "spoke_network_group_ids" {
  description = "Region => network group. A spoke joins its region's hub by becoming a member of this group."
  value       = { for k, g in azurerm_network_manager_network_group.spokes : k => g.id }
}
