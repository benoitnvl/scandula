# Hand these to whoever runs part 2 (azure-ipam/platform): they go into its
# terraform.tfvars. None of them is secret.

output "tenant_id" {
  description = "The Entra ID tenant."
  value       = data.azuread_client_config.current.tenant_id
}

output "engine_client_id" {
  description = "The engine app's client (application) id."
  value       = azuread_application_registration.engine.client_id
}

output "engine_application_id" {
  description = "The engine app's resource id (/applications/<object id>). Part 2 creates the engine secret on it."
  value       = azuread_application_registration.engine.id
}

output "ui_client_id" {
  description = "The UI app's client id. Null when ui_enabled is false."
  value       = one(azuread_application_registration.ui[*].client_id)
}

output "ui_application_id" {
  description = "The UI app's resource id. Part 2 sets its redirect URI. Null when ui_enabled is false."
  value       = one(azuread_application_registration.ui[*].id)
}

output "reader_scope" {
  description = "Where the engine has Reader."
  value       = azurerm_role_assignment.engine_reader.scope
}
