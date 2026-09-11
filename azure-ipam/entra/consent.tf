# Tenant-wide admin consent: the three grants deploy.ps1's Grant-AdminConsent makes.
# No user_object_id, so each is consentType AllPrincipals. This is why part 1 needs
# a Global Administrator.

data "azuread_service_principal" "graph" {
  client_id = local.graph_client_id
}

data "azuread_service_principal" "arm" {
  client_id = local.arm_client_id
}

# UI → Microsoft Graph: sign-in, the user's profile, and directory lookups.
resource "azuread_service_principal_delegated_permission_grant" "ui_graph" {
  count = var.ui_enabled ? 1 : 0

  service_principal_object_id          = azuread_service_principal.ui[0].object_id
  resource_service_principal_object_id = data.azuread_service_principal.graph.object_id
  claim_values                         = keys(local.graph_scopes)
}

# UI → engine: call the engine API as the signed-in user.
resource "azuread_service_principal_delegated_permission_grant" "ui_engine" {
  count = var.ui_enabled ? 1 : 0

  service_principal_object_id          = azuread_service_principal.ui[0].object_id
  resource_service_principal_object_id = azuread_service_principal.engine.object_id
  claim_values                         = ["access_as_user"]
}

# Engine → ARM: read Azure on behalf of the signed-in user.
resource "azuread_service_principal_delegated_permission_grant" "engine_arm" {
  service_principal_object_id          = azuread_service_principal.engine.object_id
  resource_service_principal_object_id = data.azuread_service_principal.arm.object_id
  claim_values                         = ["user_impersonation"]
}
