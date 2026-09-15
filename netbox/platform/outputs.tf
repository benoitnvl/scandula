output "netbox_enabled" {
  description = "Whether NetBox is built."
  value       = var.netbox_enabled
}

output "netbox_url" {
  description = "Where NetBox answers. This is NETBOX_SERVER_URL for netbox/records and for anything else using the provider. Null while netbox_enabled is off."
  value       = local.enabled ? "https://${local.netbox_fqdn}" : null
}

output "netbox_version" {
  description = "The pinned NetBox release (release.json), and the digest actually deployed."
  value = {
    version = local.release.netbox_version
    image   = local.image
  }
}

output "resource_group_name" {
  description = "NetBox's resource group. Null while netbox_enabled is off."
  value       = one(azurerm_resource_group.netbox[*].name)
}

output "virtual_network_id" {
  description = "NetBox's VNet, which holds an allocation from the AVNM region pool. Attach it to a hub from the connectivity repo when the hubs are on."
  value       = one(azurerm_virtual_network.netbox[*].id)
}

output "address_prefixes" {
  description = "What AVNM allocated to NetBox's VNet. Record it in NetBox itself (netbox/records) once NetBox is up."
  value       = local.enabled ? azurerm_virtual_network.netbox[0].ip_address_pool[0].allocated_ip_address_prefixes : null
}

output "key_vault_name" {
  description = "The vault holding the database password, the Redis key and Django's SECRET_KEY."
  value       = one(azurerm_key_vault.netbox[*].name)
}

output "identity_principal_id" {
  description = "The identity the containers run as."
  value       = one(azurerm_user_assigned_identity.netbox[*].principal_id)
}

output "log_analytics_workspace_id" {
  description = "Where the containers and the database log."
  value       = one(azurerm_log_analytics_workspace.netbox[*].id)
}
