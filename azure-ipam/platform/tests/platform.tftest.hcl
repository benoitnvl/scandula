# Part 2 (the Azure resources, the engine secret, the UI redirect, the zip deploy)
# against mocked azurerm/azuread/random/time: no Azure, no credentials, no zip.
#
#   make ipam-test
#
# tests/fixtures/ holds a stand-in zip and a release.json pinning its SHA-256, so
# the pin check runs for real (it reads the file). What this can't prove: that
# Azure accepts these resources, or that the engine starts. It pins the settings the
# engine reads, the pin check, the cost guard, and the wiring.

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "11111111-1111-1111-1111-111111111111"
      object_id       = "0e0e0e0e-0000-0000-0000-000000000001"
      client_id       = "0c0c0c0c-0000-0000-0000-000000000001"
      subscription_id = "00000000-0000-0000-0000-000000000000"
    }
  }
  mock_data "azurerm_subscription" {
    defaults = {
      id              = "/subscriptions/00000000-0000-0000-0000-000000000000"
      subscription_id = "00000000-0000-0000-0000-000000000000"
      quota_id        = "EnterpriseAgreement_2014-09-01"
      spending_limit  = "Off"
    }
  }

  mock_resource "azurerm_resource_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-scipam" }
  }
  mock_resource "azurerm_user_assigned_identity" {
    defaults = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-scipam/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-scipam"
      principal_id = "1d1d1d1d-0000-0000-0000-000000000001"
      client_id    = "1c1c1c1c-0000-0000-0000-000000000001"
    }
  }
  mock_resource "azurerm_log_analytics_workspace" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-scipam/providers/Microsoft.OperationalInsights/workspaces/log-scipam" }
  }
  mock_resource "azurerm_key_vault" {
    defaults = {
      id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-scipam/providers/Microsoft.KeyVault/vaults/kv-scipam-abc123"
      vault_uri = "https://kv-scipam-abc123.vault.azure.net/"
    }
  }
  mock_resource "azurerm_key_vault_secret" {
    defaults = {
      id             = "https://kv-scipam-abc123.vault.azure.net/secrets/ENGINE-SECRET/0123456789abcdef0123456789abcdef"
      versionless_id = "https://kv-scipam-abc123.vault.azure.net/secrets/ENGINE-SECRET"
    }
  }
  mock_resource "azurerm_cosmosdb_account" {
    defaults = {
      id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-scipam/providers/Microsoft.DocumentDB/databaseAccounts/cosmos-scipam-abc123"
      endpoint = "https://cosmos-scipam-abc123.documents.azure.com:443/"
    }
  }
  mock_resource "azurerm_cosmosdb_sql_database" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-scipam/providers/Microsoft.DocumentDB/databaseAccounts/cosmos-scipam-abc123/sqlDatabases/ipam-db" }
  }
  mock_resource "azurerm_cosmosdb_sql_container" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-scipam/providers/Microsoft.DocumentDB/databaseAccounts/cosmos-scipam-abc123/sqlDatabases/ipam-db/containers/ipam-ctr" }
  }
  mock_resource "azurerm_service_plan" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-scipam/providers/Microsoft.Web/serverFarms/asp-scipam" }
  }
  mock_resource "azurerm_linux_web_app" {
    defaults = {
      id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-scipam/providers/Microsoft.Web/sites/app-scipam-abc123"
      default_hostname = "app-scipam-abc123.azurewebsites.net"
    }
  }
}

mock_provider "azuread" {
  mock_resource "azuread_application_password" {
    defaults = {
      value  = "mock-engine-secret"
      key_id = "4b4b4b4b-0000-0000-0000-000000000001"
    }
  }
}

mock_provider "random" {
  mock_resource "random_string" {
    defaults = { result = "abc123" }
  }
}

mock_provider "time" {
  mock_resource "time_rotating" {
    defaults = {
      id      = "2026-09-11T00:00:00Z"
      rfc3339 = "2026-09-11T00:00:00Z"
    }
  }
}

variables {
  engine_client_id      = "eeeeeeee-0000-0000-0000-00000000e001"
  engine_application_id = "/applications/aaaaaaaa-0000-0000-0000-00000000e001"
  ui_client_id          = "bbbbbbbb-0000-0000-0000-00000000b001"
  ui_application_id     = "/applications/aaaaaaaa-0000-0000-0000-00000000b001"
  release_file          = "tests/fixtures/release.json"
  zip_path              = "tests/fixtures/ipam-test.zip"
}

# --- the cost guard ---------------------------------------------------------------------

run "ipam_is_off_by_default" {
  command = apply

  # Off must not even need the zip.
  variables {
    zip_path = "tests/fixtures/does-not-exist.zip"
  }

  assert {
    condition = (
      length(azurerm_resource_group.ipam) == 0 &&
      length(azurerm_service_plan.ipam) == 0 &&
      length(azurerm_linux_web_app.ipam) == 0 &&
      length(azurerm_cosmosdb_account.ipam) == 0 &&
      length(azurerm_cosmosdb_sql_database.ipam) == 0 &&
      length(azurerm_cosmosdb_sql_container.ipam) == 0 &&
      length(azurerm_key_vault.ipam) == 0 &&
      length(azurerm_log_analytics_workspace.ipam) == 0 &&
      length(azurerm_user_assigned_identity.ipam) == 0 &&
      length(azurerm_monitor_diagnostic_setting.ipam) == 0
    )
    error_message = "With ipam_enabled unset, nothing billable may be planned."
  }

  assert {
    condition = (
      length(azuread_application_password.engine) == 0 &&
      length(azuread_application_redirect_uris.ui) == 0 &&
      length(azurerm_key_vault_secret.engine_secret) == 0 &&
      length(azurerm_role_assignment.identity_resource_group) == 0 &&
      length(azurerm_role_assignment.identity_key_vault) == 0 &&
      length(azurerm_role_assignment.deployer_key_vault) == 0 &&
      length(azurerm_cosmosdb_sql_role_assignment.identity) == 0
    )
    error_message = "With ipam_enabled unset, nothing may touch Entra ID or grant a role."
  }

  assert {
    condition     = output.ipam_url == null && output.engine_secret_end_date == null
    error_message = "The outputs must be null while off."
  }
}

# --- the app --------------------------------------------------------------------------------

run "web_app_runs_the_pinned_release" {
  command = apply

  variables {
    ipam_enabled = true
  }

  assert {
    condition     = azurerm_linux_web_app.ipam[0].zip_deploy_file == "tests/fixtures/ipam-test.zip"
    error_message = "The web app must deploy the verified zip."
  }

  # Every setting the engine reads, and nothing that would make App Service rebuild
  # the app with Oryx (SCM_DO_BUILD_DURING_DEPLOYMENT) from unpinned requirements.
  assert {
    # tomap(): app_settings is a map(string), and a map never equals an object literal.
    condition = azurerm_linux_web_app.ipam[0].app_settings == tomap({
      AZURE_ENV                = "AZURE_PUBLIC"
      COSMOS_URL               = "https://cosmos-scipam-abc123.documents.azure.com:443/"
      DATABASE_NAME            = "ipam-db"
      CONTAINER_NAME           = "ipam-ctr"
      MANAGED_IDENTITY_ID      = "1c1c1c1c-0000-0000-0000-000000000001"
      TENANT_ID                = "11111111-1111-1111-1111-111111111111"
      ENGINE_APP_ID            = "eeeeeeee-0000-0000-0000-00000000e001"
      ENGINE_APP_SECRET        = "@Microsoft.KeyVault(SecretUri=https://kv-scipam-abc123.vault.azure.net/secrets/ENGINE-SECRET)"
      UI_APP_ID                = "bbbbbbbb-0000-0000-0000-00000000b001"
      WEBSITE_RUN_FROM_PACKAGE = "1"
    })
    error_message = "The app settings must be exactly what the engine reads, with the secret as a Key Vault reference and run-from-package on."
  }

  assert {
    condition = (
      azurerm_linux_web_app.ipam[0].site_config[0].application_stack[0].python_version == "3.11" &&
      azurerm_linux_web_app.ipam[0].site_config[0].app_command_line == "bash ./init.sh 8000" &&
      azurerm_linux_web_app.ipam[0].site_config[0].health_check_path == "/api/status" &&
      azurerm_linux_web_app.ipam[0].site_config[0].health_check_eviction_time_in_min == 2 &&
      azurerm_linux_web_app.ipam[0].site_config[0].always_on
    )
    error_message = "The runtime must match upstream: Python from release.json, init.sh on port 8000, /api/status health check, always on."
  }

  assert {
    condition = (
      azurerm_linux_web_app.ipam[0].https_only &&
      azurerm_linux_web_app.ipam[0].site_config[0].ftps_state == "Disabled" &&
      azurerm_linux_web_app.ipam[0].site_config[0].minimum_tls_version == "1.2" &&
      !azurerm_linux_web_app.ipam[0].ftp_publish_basic_authentication_enabled
    )
    error_message = "HTTPS only, TLS 1.2, and no FTP."
  }

  assert {
    condition = (
      azurerm_linux_web_app.ipam[0].identity[0].type == "UserAssigned" &&
      toset(azurerm_linux_web_app.ipam[0].identity[0].identity_ids) == toset([azurerm_user_assigned_identity.ipam[0].id]) &&
      azurerm_linux_web_app.ipam[0].key_vault_reference_identity_id == azurerm_user_assigned_identity.ipam[0].id
    )
    error_message = "The app must run as the managed identity, and resolve Key Vault references with it."
  }

  assert {
    condition     = azurerm_service_plan.ipam[0].sku_name == "P1v3" && azurerm_service_plan.ipam[0].os_type == "Linux"
    error_message = "The plan must be Linux P1v3, as upstream."
  }
}

# --- the engine secret ------------------------------------------------------------------

run "engine_secret_is_made_here_and_kept_in_key_vault" {
  command = apply

  variables {
    ipam_enabled = true
  }

  assert {
    condition = (
      azuread_application_password.engine[0].application_id == "/applications/aaaaaaaa-0000-0000-0000-00000000e001" &&
      azuread_application_password.engine[0].end_date == "2028-09-10T00:00:00Z" &&
      azuread_application_password.engine[0].rotate_when_changed.rotation == time_rotating.engine_secret[0].id
    )
    error_message = "The engine secret must be on the engine app, last 730 days, and be replaced when the yearly rotation fires."
  }

  assert {
    condition     = time_rotating.engine_secret[0].rotation_years == 1
    error_message = "The secret must rotate yearly, a year before it expires."
  }

  assert {
    condition = (
      azurerm_key_vault_secret.engine_secret[0].name == "ENGINE-SECRET" &&
      azurerm_key_vault_secret.engine_secret[0].value == "mock-engine-secret" &&
      azurerm_key_vault_secret.engine_secret[0].expiration_date == azuread_application_password.engine[0].end_date &&
      azurerm_key_vault_secret.engine_secret[0].key_vault_id == azurerm_key_vault.ipam[0].id
    )
    error_message = "The secret must go into the vault as ENGINE-SECRET, expiring with the password."
  }

  assert {
    condition     = azurerm_key_vault.ipam[0].rbac_authorization_enabled && azurerm_key_vault.ipam[0].purge_protection_enabled
    error_message = "The vault must use RBAC and purge protection, as upstream."
  }

  assert {
    condition = (
      azurerm_role_assignment.identity_key_vault[0].role_definition_name == "Key Vault Secrets User" &&
      azurerm_role_assignment.identity_key_vault[0].principal_id == "1d1d1d1d-0000-0000-0000-000000000001" &&
      azurerm_role_assignment.identity_key_vault[0].scope == azurerm_key_vault.ipam[0].id
    )
    error_message = "The managed identity must be able to read secrets, on this vault only."
  }

  assert {
    condition = (
      azurerm_role_assignment.deployer_key_vault[0].role_definition_name == "Key Vault Secrets Officer" &&
      azurerm_role_assignment.deployer_key_vault[0].principal_id == "0e0e0e0e-0000-0000-0000-000000000001" &&
      azurerm_role_assignment.deployer_key_vault[0].scope == azurerm_key_vault.ipam[0].id
    )
    error_message = "Whoever runs part 2 must be able to write the secret, on this vault only."
  }
}

# --- Cosmos DB and the identity's roles -----------------------------------------------

run "cosmos_matches_upstream" {
  command = apply

  variables {
    ipam_enabled = true
  }

  assert {
    condition = (
      azurerm_cosmosdb_account.ipam[0].kind == "GlobalDocumentDB" &&
      azurerm_cosmosdb_account.ipam[0].consistency_policy[0].consistency_level == "Session" &&
      azurerm_cosmosdb_account.ipam[0].automatic_failover_enabled &&
      !azurerm_cosmosdb_account.ipam[0].access_key_metadata_writes_enabled &&
      !azurerm_cosmosdb_account.ipam[0].local_authentication_enabled
    )
    error_message = "Cosmos DB must be SQL API, Session consistency, and allow managed-identity access only."
  }

  assert {
    condition = (
      azurerm_cosmosdb_sql_database.ipam[0].name == "ipam-db" &&
      azurerm_cosmosdb_sql_container.ipam[0].name == "ipam-ctr" &&
      azurerm_cosmosdb_sql_container.ipam[0].partition_key_paths == tolist(["/tenant_id"]) &&
      azurerm_cosmosdb_sql_container.ipam[0].autoscale_settings[0].max_throughput == 1000
    )
    error_message = "The database, container, partition key and autoscale ceiling must match upstream."
  }

  assert {
    condition = (
      azurerm_cosmosdb_sql_role_assignment.identity[0].role_definition_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-scipam/providers/Microsoft.DocumentDB/databaseAccounts/cosmos-scipam-abc123/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002" &&
      azurerm_cosmosdb_sql_role_assignment.identity[0].principal_id == "1d1d1d1d-0000-0000-0000-000000000001" &&
      azurerm_cosmosdb_sql_role_assignment.identity[0].scope == azurerm_cosmosdb_account.ipam[0].id
    )
    error_message = "The identity must hold Cosmos DB Built-in Data Contributor on the account."
  }

  assert {
    condition = (
      toset(keys(azurerm_role_assignment.identity_resource_group)) == toset(["Contributor", "Managed Identity Operator"]) &&
      alltrue([for r in azurerm_role_assignment.identity_resource_group : r.scope == azurerm_resource_group.ipam[0].id && r.principal_id == "1d1d1d1d-0000-0000-0000-000000000001"])
    )
    error_message = "The identity must get Contributor and Managed Identity Operator on the IPAM resource group only."
  }
}

# --- Entra: the redirect ---------------------------------------------------------------

run "ui_redirect_is_the_web_app" {
  command = apply

  variables {
    ipam_enabled = true
  }

  assert {
    condition = (
      azuread_application_redirect_uris.ui[0].application_id == "/applications/aaaaaaaa-0000-0000-0000-00000000b001" &&
      azuread_application_redirect_uris.ui[0].type == "SPA" &&
      toset(azuread_application_redirect_uris.ui[0].redirect_uris) == toset(["https://app-scipam-abc123.azurewebsites.net"])
    )
    error_message = "The UI app's only redirect must be the web app's origin, as a SPA redirect."
  }

  assert {
    condition     = output.ipam_url == "https://app-scipam-abc123.azurewebsites.net"
    error_message = "ipam_url must be the web app."
  }
}

run "api_only_install" {
  command = apply

  variables {
    ipam_enabled      = true
    ui_client_id      = null
    ui_application_id = null
  }

  assert {
    condition     = azurerm_linux_web_app.ipam[0].app_settings["UI_APP_ID"] == "00000000-0000-0000-0000-000000000000"
    error_message = "With no UI app, UI_APP_ID must be all zeros, which tells the engine not to serve the UI."
  }

  assert {
    condition     = length(azuread_application_redirect_uris.ui) == 0
    error_message = "With no UI app, there's no redirect to set."
  }
}

# --- diagnostics and names ---------------------------------------------------------------

run "diagnostics_go_to_the_workspace" {
  command = apply

  variables {
    ipam_enabled = true
  }

  assert {
    condition = (
      toset(keys(azurerm_monitor_diagnostic_setting.ipam)) == toset(["key-vault", "cosmos", "service-plan", "web-app"]) &&
      alltrue([for d in azurerm_monitor_diagnostic_setting.ipam : d.log_analytics_workspace_id == azurerm_log_analytics_workspace.ipam[0].id])
    )
    error_message = "The vault, Cosmos DB, the plan and the app must all send diagnostics to the workspace."
  }

  assert {
    condition = (
      azurerm_monitor_diagnostic_setting.ipam["cosmos"].log_analytics_destination_type == "Dedicated" &&
      length(azurerm_monitor_diagnostic_setting.ipam["service-plan"].enabled_log) == 0 &&
      length(azurerm_monitor_diagnostic_setting.ipam["web-app"].enabled_log) == 1
    )
    error_message = "Cosmos DB uses dedicated tables; the plan sends metrics only; the others send allLogs."
  }
}

run "names_fit_the_longest_prefix" {
  command = apply

  variables {
    ipam_enabled = true
    name_prefix  = "abcdefghijklmn"
  }

  assert {
    condition     = length(azurerm_key_vault.ipam[0].name) <= 24
    error_message = "A Key Vault name is 24 characters at most, even with a 14-character name_prefix."
  }

  assert {
    condition     = length(azurerm_cosmosdb_account.ipam[0].name) <= 44 && length(azurerm_linux_web_app.ipam[0].name) <= 60
    error_message = "Cosmos DB (44) and App Service (60) name limits must hold with the longest prefix."
  }
}

# --- guards --------------------------------------------------------------------------------

run "refuses_a_credit_subscription" {
  command = plan

  variables {
    ipam_enabled = true
  }

  override_data {
    target = data.azurerm_subscription.current
    values = { quota_id = "MSDN_2014-09-01", spending_limit = "Off" }
  }

  expect_failures = [azurerm_resource_group.ipam]
}

run "refuses_a_spending_limit" {
  command = plan

  variables {
    ipam_enabled = true
  }

  override_data {
    target = data.azurerm_subscription.current
    values = { quota_id = "PayAsYouGo_2014-09-01", spending_limit = "On" }
  }

  expect_failures = [azurerm_resource_group.ipam]
}

run "allows_a_credit_subscription_deliberately" {
  command = plan

  variables {
    ipam_enabled              = true
    allow_credit_subscription = true
  }

  override_data {
    target = data.azurerm_subscription.current
    values = { quota_id = "MSDN_2014-09-01", spending_limit = "On" }
  }

  assert {
    condition     = length(azurerm_resource_group.ipam) == 1
    error_message = "allow_credit_subscription = true must let it through."
  }
}

# A real .zip that exists: only the SHA-256 pin can refuse it, not azurerm's own
# checks on zip_deploy_file.
run "refuses_a_zip_that_isnt_the_pinned_one" {
  command = plan

  variables {
    ipam_enabled = true
    zip_path     = "tests/fixtures/ipam-wrong.zip"
  }

  expect_failures = [azurerm_linux_web_app.ipam]
}

run "refuses_a_missing_zip" {
  command = plan

  variables {
    ipam_enabled = true
    zip_path     = "tests/fixtures/does-not-exist.zip"
  }

  expect_failures = [azurerm_linux_web_app.ipam]
}

# --- rejections --------------------------------------------------------------------------

run "rejects_a_bad_name_prefix" {
  command = plan
  variables {
    name_prefix = "SC-ipam"
  }
  expect_failures = [var.name_prefix]
}

run "rejects_short_log_retention" {
  command = plan
  variables {
    log_retention_days = 7
  }
  expect_failures = [var.log_retention_days]
}

run "rejects_a_bad_engine_client_id" {
  command = plan
  variables {
    engine_client_id = "not-a-guid"
  }
  expect_failures = [var.engine_client_id]
}

run "rejects_an_engine_object_id_without_its_prefix" {
  command = plan
  variables {
    engine_application_id = "aaaaaaaa-0000-0000-0000-00000000e001"
  }
  expect_failures = [var.engine_application_id]
}

run "rejects_a_bad_ui_client_id" {
  command = plan
  variables {
    ui_client_id = "not-a-guid"
  }
  expect_failures = [var.ui_client_id]
}

run "rejects_a_ui_object_id_without_its_prefix" {
  command = plan
  variables {
    ui_application_id = "aaaaaaaa-0000-0000-0000-00000000b001"
  }
  expect_failures = [var.ui_application_id]
}

run "rejects_half_a_ui" {
  command = plan
  variables {
    ui_application_id = null
  }
  expect_failures = [var.ui_application_id]
}
