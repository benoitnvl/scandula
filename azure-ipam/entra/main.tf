# What Azure/ipam v3.6.0's `deploy.ps1 -AppsOnly` creates in Entra ID, as Terraform.
# Two deliberate differences:
#   - No client secret. Part 2's identities own both apps (platform_owner_object_ids),
#     so part 2 creates the engine secret and puts it straight into Key Vault. Nothing
#     secret is handed over, or kept in this root's state.
#   - No placeholder redirect URI. Part 2 sets the real one once the web app exists.
#
# The split azuread resources are what break the loops: the engine's identifier URI
# names its own client id, the UI's API access names the engine, and the engine's
# known clients name the UI.

data "azuread_client_config" "current" {}

# --- engine ---------------------------------------------------------------------

resource "azuread_application_registration" "engine" {
  display_name     = var.engine_app_name
  sign_in_audience = "AzureADMyOrg"
  notes            = local.notes

  # The engine rejects v1 tokens (engine/app/dependencies.py).
  requested_access_token_version = 2
}

# The UI hard-codes api://<engine client id> (ui/src/msal/authConfig.jsx).
resource "azuread_application_identifier_uri" "engine" {
  application_id = azuread_application_registration.engine.id
  identifier_uri = "api://${azuread_application_registration.engine.client_id}"
}

# deploy.ps1 makes a new scope id on every run; this keeps one per install.
resource "random_uuid" "engine_scope" {}

resource "azuread_application_permission_scope" "engine_access_as_user" {
  application_id = azuread_application_registration.engine.id
  scope_id       = random_uuid.engine_scope.result
  value          = "access_as_user"
  type           = "User"

  admin_consent_display_name = "Access IPAM Engine API"
  admin_consent_description  = "Allows the IPAM UI to access IPAM Engine API as the signed-in user."
  user_consent_display_name  = "Access IPAM Engine API"
  user_consent_description   = "Allow the IPAM UI to access IPAM Engine API on your behalf."
}

# Lets Azure PowerShell and the Azure CLI get engine tokens without a consent prompt.
resource "azuread_application_pre_authorized" "engine" {
  for_each = {
    azure-powershell = local.azure_powershell_client_id
    azure-cli        = local.azure_cli_client_id
  }

  application_id       = azuread_application_registration.engine.id
  authorized_client_id = each.value
  permission_ids       = [azuread_application_permission_scope.engine_access_as_user.scope_id]
}

# The engine calls ARM on behalf of the signed-in user.
resource "azuread_application_api_access" "engine_arm" {
  application_id = azuread_application_registration.engine.id
  api_client_id  = local.arm_client_id
  scope_ids      = [local.arm_user_impersonation_id]
}

resource "azuread_service_principal" "engine" {
  client_id = azuread_application_registration.engine.client_id
  notes     = local.notes
}

# Discovery: the engine reads every subscription under this management group.
resource "azurerm_role_assignment" "engine_reader" {
  scope                = local.reader_scope
  role_definition_name = "Reader"
  principal_id         = azuread_service_principal.engine.object_id
  principal_type       = "ServicePrincipal"
}

# --- UI (skipped when ui_enabled is false) --------------------------------------

resource "azuread_application_registration" "ui" {
  count = var.ui_enabled ? 1 : 0

  display_name     = var.ui_app_name
  sign_in_audience = "AzureADMyOrg"
  notes            = local.notes
}

resource "azuread_application_api_access" "ui_graph" {
  count = var.ui_enabled ? 1 : 0

  application_id = azuread_application_registration.ui[0].id
  api_client_id  = local.graph_client_id
  scope_ids      = values(local.graph_scopes)
}

resource "azuread_application_api_access" "ui_engine" {
  count = var.ui_enabled ? 1 : 0

  application_id = azuread_application_registration.ui[0].id
  api_client_id  = azuread_application_registration.engine.client_id
  scope_ids      = [azuread_application_permission_scope.engine_access_as_user.scope_id]
}

resource "azuread_application_known_clients" "engine" {
  count = var.ui_enabled ? 1 : 0

  application_id   = azuread_application_registration.engine.id
  known_client_ids = [azuread_application_registration.ui[0].client_id]
}

resource "azuread_service_principal" "ui" {
  count = var.ui_enabled ? 1 : 0

  client_id = azuread_application_registration.ui[0].client_id
  notes     = local.notes
}

# --- owners: part 2's identities ------------------------------------------------

resource "azuread_application_owner" "engine" {
  for_each = toset(var.platform_owner_object_ids)

  application_id  = azuread_application_registration.engine.id
  owner_object_id = each.value
}

resource "azuread_application_owner" "ui" {
  for_each = var.ui_enabled ? toset(var.platform_owner_object_ids) : toset([])

  application_id  = azuread_application_registration.ui[0].id
  owner_object_id = each.value
}
