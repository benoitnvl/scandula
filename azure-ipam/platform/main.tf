# What Azure/ipam v3.6.0's main.bicep deploys, plus what deploy.ps1 does after it
# (the engine secret, the UI redirect URI, the zip deploy), as Terraform. Built only
# with ipam_enabled = true.
#
# Deliberate differences from upstream, each for a reason:
#   - Run-from-package (WEBSITE_RUN_FROM_PACKAGE=1), not an Oryx build. Oryx installs
#     the engine's unpinned requirements.txt; the zip's packages/ come from upstream's
#     lock file, so the zip's SHA-256 pins everything. init.sh and the Bicep already
#     use this path for one cloud (AZURE_US_GOV_SECRET).
#   - Stable names with one random suffix, not new resources on every run.
#   - Only the engine secret goes into Key Vault. Upstream also stores the tenant id,
#     client ids and identity id there; they aren't secret, so they're plain settings.
#   - Cosmos DB local (key) auth is off. The engine uses the managed identity whenever
#     COSMOS_KEY is unset, and nothing sets it.
#   - FTPS off, TLS 1.2 minimum. Upstream leaves them at Azure's defaults.

data "azurerm_client_config" "current" {}

data "azurerm_subscription" "current" {
  count = var.ipam_enabled ? 1 : 0
}

resource "random_string" "suffix" {
  count = var.ipam_enabled ? 1 : 0

  length  = 6
  upper   = false
  special = false
}

resource "azurerm_resource_group" "ipam" {
  count = var.ipam_enabled ? 1 : 0

  name     = local.names.resource_group
  location = var.location
  tags     = local.tags

  lifecycle {
    precondition {
      condition = var.allow_credit_subscription || !(
        can(regex(local.credit_offer_pattern, data.azurerm_subscription.current[0].quota_id)) ||
        data.azurerm_subscription.current[0].spending_limit == "On"
      )
      error_message = "This is a credit or trial subscription, or has a spending limit. Azure IPAM costs about $170-250/month and would use up the credit, and then Azure disables the subscription. Use a paid subscription, or set allow_credit_subscription = true deliberately."
    }
  }
}

# --- identity ----------------------------------------------------------------------

# The app runs as this identity: Key Vault references, Cosmos DB data access.
resource "azurerm_user_assigned_identity" "ipam" {
  count = var.ipam_enabled ? 1 : 0

  name                = local.names.identity
  resource_group_name = azurerm_resource_group.ipam[0].name
  location            = var.location
  tags                = local.tags
}

# As upstream's managedIdentity.bicep: both on the IPAM resource group.
resource "azurerm_role_assignment" "identity_resource_group" {
  for_each = var.ipam_enabled ? toset(["Contributor", "Managed Identity Operator"]) : toset([])

  scope                = azurerm_resource_group.ipam[0].id
  role_definition_name = each.value
  principal_id         = azurerm_user_assigned_identity.ipam[0].principal_id
  principal_type       = "ServicePrincipal"
}

# --- logs --------------------------------------------------------------------------

resource "azurerm_log_analytics_workspace" "ipam" {
  count = var.ipam_enabled ? 1 : 0

  name                = local.names.log_analytics
  resource_group_name = azurerm_resource_group.ipam[0].name
  location            = var.location
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days
  tags                = local.tags
}

# --- Key Vault: the engine secret ----------------------------------------------------

resource "azurerm_key_vault" "ipam" {
  count = var.ipam_enabled ? 1 : 0

  name                = local.names.key_vault
  resource_group_name = azurerm_resource_group.ipam[0].name
  location            = var.location
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"
  tags                = local.tags

  rbac_authorization_enabled = true
  purge_protection_enabled   = true
  soft_delete_retention_days = 90

  # As upstream: the app reads the secret over the public endpoint (no VNet
  # integration), so the vault can't be closed to the internet.
  public_network_access_enabled = true
  network_acls {
    default_action = "Allow"
    bypass         = "AzureServices"
  }
}

resource "azurerm_role_assignment" "identity_key_vault" {
  count = var.ipam_enabled ? 1 : 0

  scope                = azurerm_key_vault.ipam[0].id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.ipam[0].principal_id
  principal_type       = "ServicePrincipal"
}

# Terraform writes the secret through the vault's data plane, which ARM roles don't
# cover. Upstream's Bicep writes it through ARM, so it never needed this.
resource "azurerm_role_assignment" "deployer_key_vault" {
  count = var.ipam_enabled ? 1 : 0

  scope                = azurerm_key_vault.ipam[0].id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Data-plane role assignments take a while to reach Key Vault.
resource "time_sleep" "key_vault_rbac" {
  count = var.ipam_enabled ? 1 : 0

  create_duration = "120s"
  triggers = {
    role_assignment = azurerm_role_assignment.deployer_key_vault[0].id
  }
}

# The engine's client secret. Part 2 owns the engine app (part 1 made it an owner),
# so the secret is created here and goes straight into Key Vault: nothing is handed
# over. It lasts two years, as upstream's does, and is replaced after one, on the
# first apply after that. Run an apply at least once a year.
resource "time_rotating" "engine_secret" {
  count = var.ipam_enabled ? 1 : 0

  rotation_years = 1
}

resource "azuread_application_password" "engine" {
  count = var.ipam_enabled ? 1 : 0

  application_id = var.engine_application_id
  display_name   = "azure-ipam platform (benoitnvl/scandula)"
  end_date       = timeadd(time_rotating.engine_secret[0].rfc3339, "17520h") # 730 days

  rotate_when_changed = {
    rotation = time_rotating.engine_secret[0].id
  }
}

resource "azurerm_key_vault_secret" "engine_secret" {
  count = var.ipam_enabled ? 1 : 0

  name            = "ENGINE-SECRET"
  key_vault_id    = azurerm_key_vault.ipam[0].id
  value           = azuread_application_password.engine[0].value
  content_type    = "Entra ID client secret (azure-ipam engine)"
  expiration_date = azuread_application_password.engine[0].end_date

  depends_on = [time_sleep.key_vault_rbac]
}

# --- Cosmos DB -----------------------------------------------------------------------

resource "azurerm_cosmosdb_account" "ipam" {
  count = var.ipam_enabled ? 1 : 0

  name                = local.names.cosmos
  resource_group_name = azurerm_resource_group.ipam[0].name
  location            = var.location
  offer_type          = "Standard"
  kind                = "GlobalDocumentDB"
  tags                = local.tags

  automatic_failover_enabled         = true
  access_key_metadata_writes_enabled = false
  local_authentication_enabled       = false
  minimal_tls_version                = "Tls12"

  consistency_policy {
    consistency_level = "Session"
  }

  geo_location {
    location          = var.location
    failover_priority = 0
  }
}

resource "azurerm_cosmosdb_sql_database" "ipam" {
  count = var.ipam_enabled ? 1 : 0

  name                = "ipam-db"
  resource_group_name = azurerm_resource_group.ipam[0].name
  account_name        = azurerm_cosmosdb_account.ipam[0].name
}

resource "azurerm_cosmosdb_sql_container" "ipam" {
  count = var.ipam_enabled ? 1 : 0

  name                = "ipam-ctr"
  resource_group_name = azurerm_resource_group.ipam[0].name
  account_name        = azurerm_cosmosdb_account.ipam[0].name
  database_name       = azurerm_cosmosdb_sql_database.ipam[0].name
  partition_key_paths = ["/tenant_id"]
  partition_key_kind  = "Hash"

  autoscale_settings {
    max_throughput = 1000
  }

  indexing_policy {
    indexing_mode = "consistent"
    included_path {
      path = "/*"
    }
    excluded_path {
      path = "/\"_etag\"/?"
    }
  }
}

# Cosmos DB Built-in Data Contributor, on the data plane.
resource "azurerm_cosmosdb_sql_role_assignment" "identity" {
  count = var.ipam_enabled ? 1 : 0

  resource_group_name = azurerm_resource_group.ipam[0].name
  account_name        = azurerm_cosmosdb_account.ipam[0].name
  role_definition_id  = "${azurerm_cosmosdb_account.ipam[0].id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002"
  principal_id        = azurerm_user_assigned_identity.ipam[0].principal_id
  scope               = azurerm_cosmosdb_account.ipam[0].id
}

# --- App Service ---------------------------------------------------------------------

resource "azurerm_service_plan" "ipam" {
  count = var.ipam_enabled ? 1 : 0

  name                = local.names.service_plan
  resource_group_name = azurerm_resource_group.ipam[0].name
  location            = var.location
  os_type             = "Linux"
  sku_name            = "P1v3"
  tags                = local.tags
}

resource "azurerm_linux_web_app" "ipam" {
  count = var.ipam_enabled ? 1 : 0

  name                = local.names.web_app
  resource_group_name = azurerm_resource_group.ipam[0].name
  location            = var.location
  service_plan_id     = azurerm_service_plan.ipam[0].id
  tags                = local.tags

  https_only                      = true
  client_affinity_enabled         = false
  key_vault_reference_identity_id = azurerm_user_assigned_identity.ipam[0].id

  # zip_deploy_file publishes with the site's basic-auth deployment credentials.
  webdeploy_publish_basic_authentication_enabled = true
  ftp_publish_basic_authentication_enabled       = false

  # The pinned release. A new version is a new path, so bumping it redeploys.
  zip_deploy_file = local.zip_path

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.ipam[0].id]
  }

  site_config {
    always_on                         = true
    app_command_line                  = "bash ./init.sh 8000"
    health_check_path                 = "/api/status"
    health_check_eviction_time_in_min = 2
    ftps_state                        = "Disabled"
    minimum_tls_version               = "1.2"
    http2_enabled                     = true

    application_stack {
      python_version = local.release.python_version
    }
  }

  # What the engine reads (engine/app/globals.py, main.py).
  app_settings = {
    AZURE_ENV           = "AZURE_PUBLIC"
    COSMOS_URL          = azurerm_cosmosdb_account.ipam[0].endpoint
    DATABASE_NAME       = azurerm_cosmosdb_sql_database.ipam[0].name
    CONTAINER_NAME      = azurerm_cosmosdb_sql_container.ipam[0].name
    MANAGED_IDENTITY_ID = azurerm_user_assigned_identity.ipam[0].client_id
    TENANT_ID           = data.azurerm_client_config.current.tenant_id
    ENGINE_APP_ID       = var.engine_client_id
    ENGINE_APP_SECRET   = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault_secret.engine_secret[0].versionless_id})"
    # All zeros tells the engine not to serve the UI.
    UI_APP_ID = coalesce(var.ui_client_id, "00000000-0000-0000-0000-000000000000")
    # Run the zip as it is: its packages/ are the pinned dependencies (init.sh).
    WEBSITE_RUN_FROM_PACKAGE = "1"
  }

  logs {
    detailed_error_messages = true
    failed_request_tracing  = true

    http_logs {
      file_system {
        retention_in_days = 7
        retention_in_mb   = 50
      }
    }
  }

  depends_on = [
    azurerm_role_assignment.identity_key_vault,
    azurerm_cosmosdb_sql_role_assignment.identity,
  ]

  lifecycle {
    precondition {
      condition     = try(filesha256(local.zip_path), "") == local.release.zip_sha256
      error_message = "The release zip is missing or isn't the pinned one: its SHA-256 must be release.json's zip_sha256. Run `make ipam-fetch`. If it still differs, the release asset changed upstream: stop and investigate."
    }
  }
}

# --- Entra: what deploy.ps1 does after the Bicep ------------------------------------

# The UI signs in with redirectUri = window.location.origin, so exactly this.
resource "azuread_application_redirect_uris" "ui" {
  count = var.ipam_enabled && local.ui_enabled ? 1 : 0

  application_id = var.ui_application_id
  type           = "SPA"
  redirect_uris  = ["https://${azurerm_linux_web_app.ipam[0].default_hostname}"]
}
