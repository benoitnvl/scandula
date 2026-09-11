output "ipam_enabled" {
  description = "Whether Azure IPAM is built (the cost guard)."
  value       = var.ipam_enabled
}

output "ipam_url" {
  description = "Azure IPAM's URL. Null while ipam_enabled is off."
  value       = one([for app in azurerm_linux_web_app.ipam : "https://${app.default_hostname}"])
}

output "resource_group_name" {
  description = "The resource group holding everything. Null while off."
  value       = one(azurerm_resource_group.ipam[*].name)
}

output "web_app_name" {
  description = "The App Service. Null while off."
  value       = one(azurerm_linux_web_app.ipam[*].name)
}

output "release" {
  description = "The pinned Azure IPAM release."
  value       = local.release.version
}

output "engine_secret_end_date" {
  description = "When the engine's current client secret expires. An apply after its first year replaces it."
  value       = one(azuread_application_password.engine[*].end_date)
}
