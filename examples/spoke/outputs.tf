output "resource_group_name" {
  description = "The spoke's resource group."
  value       = azurerm_resource_group.this.name
}

output "virtual_network_id" {
  description = "The spoke VNet."
  value       = azurerm_virtual_network.this.id
}

output "address_prefixes" {
  description = "What AVNM allocated to the VNet. Known only after apply — this is the answer to \"what range did we get?\"."
  value       = azurerm_virtual_network.this.ip_address_pool[0].allocated_ip_address_prefixes
}

output "subnet_address_prefixes" {
  description = "Subnet name => the prefix AVNM allocated to it. Feed these to scandula's east_west_flows when a flow needs naming."
  value       = { for k, s in azurerm_subnet.this : k => s.ip_address_pool[0].allocated_ip_address_prefixes }
}

output "subnet_ids" {
  description = "Subnet name => id, for whatever the workload puts in them."
  value       = { for k, s in azurerm_subnet.this : k => s.id }
}

output "hub_connection_id" {
  description = "The connection to the secured hub, or null while virtual_hub_id is unset."
  value       = one(azurerm_virtual_hub_connection.this[*].id)
}
