# Part 1 (Entra ID) against mocked azuread/azurerm/random: no tenant, no credentials.
#
#   make ipam-test
#
# What this can't prove: that Entra accepts these objects, or that the IPAM UI can
# sign in with them. It pins every value taken from Azure/ipam v3.6.0 deploy.ps1
# (ids, scopes, consent grants, token version, identifier URI) and the wiring
# between the two apps. Only a real part 1 run proves the rest.

mock_provider "azuread" {
  mock_data "azuread_client_config" {
    defaults = {
      tenant_id = "11111111-1111-1111-1111-111111111111"
      object_id = "22222222-2222-2222-2222-222222222222"
      client_id = "04b07795-8ddb-461a-bbee-02f9e1bf7b46"
    }
  }
  mock_resource "azuread_application_registration" {
    defaults = {
      id        = "/applications/aaaaaaaa-0000-0000-0000-000000000000"
      object_id = "aaaaaaaa-0000-0000-0000-000000000000"
      client_id = "cccccccc-0000-0000-0000-000000000000"
    }
  }
  mock_resource "azuread_service_principal" {
    defaults = { object_id = "5e5e5e5e-0000-0000-0000-000000000000" }
  }
}

mock_provider "azurerm" {}

mock_provider "random" {
  mock_resource "random_uuid" {
    defaults = { result = "33333333-3333-3333-3333-333333333333" }
  }
}

# The two apps, two SPs and two first-party SPs must be told apart, so each gets
# its own ids. That's what makes the wiring assertions below meaningful.
override_resource {
  target = azuread_application_registration.engine
  values = {
    id        = "/applications/aaaaaaaa-0000-0000-0000-00000000e001"
    object_id = "aaaaaaaa-0000-0000-0000-00000000e001"
    client_id = "eeeeeeee-0000-0000-0000-00000000e001"
  }
}

override_resource {
  target = azuread_application_registration.ui
  values = {
    id        = "/applications/aaaaaaaa-0000-0000-0000-00000000b001"
    object_id = "aaaaaaaa-0000-0000-0000-00000000b001"
    client_id = "bbbbbbbb-0000-0000-0000-00000000b001"
  }
}

override_resource {
  target = azuread_service_principal.engine
  values = { object_id = "5e5e5e5e-0000-0000-0000-00000000e001" }
}

override_resource {
  target = azuread_service_principal.ui
  values = { object_id = "5e5e5e5e-0000-0000-0000-00000000b001" }
}

override_data {
  target = data.azuread_service_principal.graph
  values = { object_id = "9a9a9a9a-0000-0000-0000-000000000001" }
}

override_data {
  target = data.azuread_service_principal.arm
  values = { object_id = "a4a4a4a4-0000-0000-0000-000000000001" }
}

variables {
  platform_owner_object_ids = ["0e0e0e0e-0000-0000-0000-000000000001"]
}

# --- engine ------------------------------------------------------------------------

run "engine_app_matches_upstream" {
  command = apply

  assert {
    condition     = azuread_application_registration.engine.sign_in_audience == "AzureADMyOrg"
    error_message = "The engine app must be single-tenant, as deploy.ps1 leaves it."
  }

  assert {
    condition     = azuread_application_registration.engine.requested_access_token_version == 2
    error_message = "The engine rejects v1 tokens: requested_access_token_version must be 2."
  }

  assert {
    condition     = azuread_application_identifier_uri.engine.identifier_uri == "api://eeeeeeee-0000-0000-0000-00000000e001"
    error_message = "The UI hard-codes api://<engine client id>; the identifier URI must be exactly that."
  }

  assert {
    condition = (
      azuread_application_permission_scope.engine_access_as_user.value == "access_as_user" &&
      azuread_application_permission_scope.engine_access_as_user.type == "User" &&
      azuread_application_permission_scope.engine_access_as_user.scope_id == "33333333-3333-3333-3333-333333333333" &&
      azuread_application_permission_scope.engine_access_as_user.application_id == azuread_application_registration.engine.id
    )
    error_message = "The engine must expose one User scope, access_as_user, with the generated scope id."
  }

  assert {
    condition = (
      azuread_application_pre_authorized.engine["azure-powershell"].authorized_client_id == "1950a258-227b-4e31-a9cf-717495945fc2" &&
      azuread_application_pre_authorized.engine["azure-cli"].authorized_client_id == "04b07795-8ddb-461a-bbee-02f9e1bf7b46" &&
      alltrue([for p in azuread_application_pre_authorized.engine : p.permission_ids == toset(["33333333-3333-3333-3333-333333333333"])])
    )
    error_message = "Azure PowerShell and the Azure CLI must be pre-authorized for access_as_user."
  }

  assert {
    condition = (
      azuread_application_api_access.engine_arm.api_client_id == "797f4846-ba00-4fd7-ba43-dac1f8f63013" &&
      azuread_application_api_access.engine_arm.scope_ids == toset(["41094075-9dad-400e-a0bd-54e686782033"])
    )
    error_message = "The engine must request ARM user_impersonation."
  }

  assert {
    condition = (
      azurerm_role_assignment.engine_reader.scope == "/providers/Microsoft.Management/managementGroups/11111111-1111-1111-1111-111111111111" &&
      azurerm_role_assignment.engine_reader.role_definition_name == "Reader" &&
      azurerm_role_assignment.engine_reader.principal_id == "5e5e5e5e-0000-0000-0000-00000000e001"
    )
    error_message = "The engine's service principal must get Reader at the tenant root management group by default."
  }
}

# --- UI and the links between the apps -----------------------------------------------

run "ui_app_matches_upstream" {
  command = apply

  assert {
    condition     = azuread_application_registration.ui[0].sign_in_audience == "AzureADMyOrg"
    error_message = "The UI app must be single-tenant."
  }

  assert {
    condition = (
      azuread_application_api_access.ui_graph[0].api_client_id == "00000003-0000-0000-c000-000000000000" &&
      azuread_application_api_access.ui_graph[0].scope_ids == toset([
        "37f7f235-527c-4136-accd-4a02d197296e",
        "14dad69e-099b-42c9-810b-d002981feec1",
        "7427e0e9-2fba-42fe-b0c0-848c9e6a8182",
        "e1fe6dd8-ba31-4d61-89e7-88639da4683d",
        "06da0dbc-49e2-44d2-8312-53f166ab848a",
      ])
    )
    error_message = "The UI must request exactly openid, profile, offline_access, User.Read and Directory.Read.All from Graph."
  }

  assert {
    condition = (
      azuread_application_api_access.ui_engine[0].application_id == azuread_application_registration.ui[0].id &&
      azuread_application_api_access.ui_engine[0].api_client_id == azuread_application_registration.engine.client_id &&
      azuread_application_api_access.ui_engine[0].scope_ids == toset([azuread_application_permission_scope.engine_access_as_user.scope_id])
    )
    error_message = "The UI must request the engine's access_as_user scope."
  }

  assert {
    condition = (
      azuread_application_known_clients.engine[0].application_id == azuread_application_registration.engine.id &&
      azuread_application_known_clients.engine[0].known_client_ids == toset([azuread_application_registration.ui[0].client_id])
    )
    error_message = "The UI must be a known client of the engine."
  }

  assert {
    condition     = azuread_service_principal.ui[0].client_id == azuread_application_registration.ui[0].client_id
    error_message = "The UI needs a service principal of its own."
  }
}

# --- consent --------------------------------------------------------------------------

run "consent_matches_upstream" {
  command = apply

  assert {
    condition = (
      azuread_service_principal_delegated_permission_grant.ui_graph[0].service_principal_object_id == "5e5e5e5e-0000-0000-0000-00000000b001" &&
      azuread_service_principal_delegated_permission_grant.ui_graph[0].resource_service_principal_object_id == "9a9a9a9a-0000-0000-0000-000000000001" &&
      toset(azuread_service_principal_delegated_permission_grant.ui_graph[0].claim_values) == toset(["openid", "profile", "offline_access", "User.Read", "Directory.Read.All"])
    )
    error_message = "UI → Graph consent must cover exactly the five delegated scopes."
  }

  assert {
    condition = (
      azuread_service_principal_delegated_permission_grant.ui_engine[0].service_principal_object_id == "5e5e5e5e-0000-0000-0000-00000000b001" &&
      azuread_service_principal_delegated_permission_grant.ui_engine[0].resource_service_principal_object_id == "5e5e5e5e-0000-0000-0000-00000000e001" &&
      toset(azuread_service_principal_delegated_permission_grant.ui_engine[0].claim_values) == toset(["access_as_user"])
    )
    error_message = "UI → engine consent must be access_as_user."
  }

  assert {
    condition = (
      azuread_service_principal_delegated_permission_grant.engine_arm.service_principal_object_id == "5e5e5e5e-0000-0000-0000-00000000e001" &&
      azuread_service_principal_delegated_permission_grant.engine_arm.resource_service_principal_object_id == "a4a4a4a4-0000-0000-0000-000000000001" &&
      toset(azuread_service_principal_delegated_permission_grant.engine_arm.claim_values) == toset(["user_impersonation"])
    )
    error_message = "Engine → ARM consent must be user_impersonation."
  }

  # No user_object_id means consentType AllPrincipals: consent for the whole tenant.
  assert {
    condition = alltrue([
      azuread_service_principal_delegated_permission_grant.ui_graph[0].user_object_id == null,
      azuread_service_principal_delegated_permission_grant.ui_engine[0].user_object_id == null,
      azuread_service_principal_delegated_permission_grant.engine_arm.user_object_id == null,
    ])
    error_message = "Every grant must be tenant-wide (no user_object_id), as deploy.ps1's AllPrincipals grants are."
  }
}

# --- owners: how part 2 gets in without a handed-over secret ------------------------

run "platform_identities_own_both_apps" {
  command = apply

  variables {
    platform_owner_object_ids = ["0e0e0e0e-0000-0000-0000-000000000001", "0e0e0e0e-0000-0000-0000-000000000002"]
  }

  assert {
    condition = (
      toset([for o in azuread_application_owner.engine : o.owner_object_id]) == toset(["0e0e0e0e-0000-0000-0000-000000000001", "0e0e0e0e-0000-0000-0000-000000000002"]) &&
      alltrue([for o in azuread_application_owner.engine : o.application_id == azuread_application_registration.engine.id])
    )
    error_message = "Every platform identity must own the engine app, so part 2 can create its secret."
  }

  assert {
    condition = (
      toset([for o in azuread_application_owner.ui : o.owner_object_id]) == toset(["0e0e0e0e-0000-0000-0000-000000000001", "0e0e0e0e-0000-0000-0000-000000000002"]) &&
      alltrue([for o in azuread_application_owner.ui : o.application_id == azuread_application_registration.ui[0].id])
    )
    error_message = "Every platform identity must own the UI app, so part 2 can set its redirect URI."
  }

  assert {
    condition     = output.engine_application_id == azuread_application_registration.engine.id && output.ui_application_id == azuread_application_registration.ui[0].id
    error_message = "The outputs part 2 needs must be the apps' resource ids."
  }
}

# --- API only ---------------------------------------------------------------------------

run "ui_disabled_is_api_only" {
  command = apply

  variables {
    ui_enabled = false
  }

  assert {
    condition = (
      length(azuread_application_registration.ui) == 0 &&
      length(azuread_service_principal.ui) == 0 &&
      length(azuread_application_api_access.ui_graph) == 0 &&
      length(azuread_application_api_access.ui_engine) == 0 &&
      length(azuread_application_known_clients.engine) == 0 &&
      length(azuread_application_owner.ui) == 0
    )
    error_message = "With ui_enabled = false there must be no UI app, and nothing that points at one."
  }

  assert {
    condition     = length(azuread_service_principal_delegated_permission_grant.ui_graph) == 0 && length(azuread_service_principal_delegated_permission_grant.ui_engine) == 0
    error_message = "With ui_enabled = false there must be no Graph (Directory.Read.All) or engine consent for a UI."
  }

  assert {
    condition     = length([for g in [azuread_service_principal_delegated_permission_grant.engine_arm] : g]) == 1
    error_message = "The engine's ARM consent is needed with or without the UI."
  }

  assert {
    condition     = output.ui_client_id == null && output.ui_application_id == null
    error_message = "The UI outputs must be null when there is no UI."
  }
}

run "reader_scope_can_be_narrowed" {
  command = apply

  variables {
    reader_management_group_id = "/providers/Microsoft.Management/managementGroups/mg-landing-zones"
  }

  assert {
    condition     = azurerm_role_assignment.engine_reader.scope == "/providers/Microsoft.Management/managementGroups/mg-landing-zones"
    error_message = "reader_management_group_id must set the engine's Reader scope."
  }
}

# --- rejections ------------------------------------------------------------------------

run "rejects_a_short_reader_management_group_id" {
  command = plan
  variables {
    reader_management_group_id = "mg-landing-zones"
  }
  expect_failures = [var.reader_management_group_id]
}

run "rejects_no_platform_owner" {
  command = plan
  variables {
    platform_owner_object_ids = []
  }
  expect_failures = [var.platform_owner_object_ids]
}
