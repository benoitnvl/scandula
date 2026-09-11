locals {
  # Well-known first-party application (client) ids: the same in every tenant.
  # Taken from Azure/ipam v3.6.0 deploy/deploy.ps1 (public cloud).
  graph_client_id            = "00000003-0000-0000-c000-000000000000" # Microsoft Graph
  arm_client_id              = "797f4846-ba00-4fd7-ba43-dac1f8f63013" # Windows Azure Service Management API
  azure_powershell_client_id = "1950a258-227b-4e31-a9cf-717495945fc2"
  azure_cli_client_id        = "04b07795-8ddb-461a-bbee-02f9e1bf7b46"

  arm_user_impersonation_id = "41094075-9dad-400e-a0bd-54e686782033"

  # Delegated Graph permissions the UI signs in with (ui/src/msal/authConfig.jsx).
  graph_scopes = {
    "openid"             = "37f7f235-527c-4136-accd-4a02d197296e"
    "profile"            = "14dad69e-099b-42c9-810b-d002981feec1"
    "offline_access"     = "7427e0e9-2fba-42fe-b0c0-848c9e6a8182"
    "User.Read"          = "e1fe6dd8-ba31-4d61-89e7-88639da4683d"
    "Directory.Read.All" = "06da0dbc-49e2-44d2-8312-53f166ab848a"
  }

  reader_scope = coalesce(var.reader_management_group_id, "/providers/Microsoft.Management/managementGroups/${data.azuread_client_config.current.tenant_id}")

  notes = "Azure IPAM. Managed from benoitnvl/scandula (azure-ipam/entra)."
}
