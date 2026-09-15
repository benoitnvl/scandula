# NetBox (netbox-community/netbox), self-hosted on Azure Container Apps, as the
# authority for Aberdeen's address plan. Built only with netbox_enabled = true.
#
# The shape mirrors what netbox-docker runs, with Azure's managed services in place
# of its containers:
#   - the web container            → a Container App with ingress
#   - the rqworker container       → a second Container App, no ingress
#   - housekeeping (a daily cron)  → a Container Apps Job on a schedule
#   - postgres                     → PostgreSQL Flexible Server, VNet-injected
#   - redis + redis-cache          → one Azure Cache for Redis, databases 0 and 1
#   - the media/reports/scripts volumes → an Azure Files share
#
# The image is pinned by digest (release.json), not by tag, and the NetBox version is
# chosen to match what the Terraform provider is tested against — netbox/README.md.

data "azurerm_client_config" "current" {}

data "azurerm_subscription" "current" {
  count = local.enabled ? 1 : 0
}

resource "random_string" "suffix" {
  count = local.enabled ? 1 : 0

  length  = 6
  upper   = false
  special = false
}

resource "azurerm_resource_group" "netbox" {
  count = local.enabled ? 1 : 0

  name     = local.names.resource_group
  location = var.location
  tags     = local.tags

  lifecycle {
    precondition {
      condition = var.allow_credit_subscription || !(
        can(regex(local.credit_offer_pattern, data.azurerm_subscription.current[0].quota_id)) ||
        data.azurerm_subscription.current[0].spending_limit == "On"
      )
      error_message = "This is a credit or trial subscription, or has a spending limit. NetBox runs continuously at about $60-100/month and would use up the credit, and then Azure disables the subscription — the tfstate account with it. Use a paid subscription, or set allow_credit_subscription = true deliberately."
    }
  }
}

# --- identity ----------------------------------------------------------------------

# The containers run as this identity, and read their secrets from Key Vault with it.
resource "azurerm_user_assigned_identity" "netbox" {
  count = local.enabled ? 1 : 0

  name                = local.names.identity
  resource_group_name = azurerm_resource_group.netbox[0].name
  location            = var.location
  tags                = local.tags
}

# --- secrets -----------------------------------------------------------------------

# Django's SECRET_KEY. NetBox requires at least 50 characters, and rotating it
# invalidates sessions — so it is generated once and kept.
resource "random_password" "secret_key" {
  count = local.enabled ? 1 : 0

  length  = 64
  special = true
  # Django reads this from an environment variable; keep the shell-awkward ones out.
  override_special = "-_=+"
}

resource "random_password" "postgres" {
  count = local.enabled ? 1 : 0

  length           = 32
  special          = true
  override_special = "-_=+"
}

resource "azurerm_key_vault" "netbox" {
  count = local.enabled ? 1 : 0

  name                       = local.names.key_vault
  resource_group_name        = azurerm_resource_group.netbox[0].name
  location                   = var.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  purge_protection_enabled   = true
  soft_delete_retention_days = 90
  rbac_authorization_enabled = true
  tags                       = local.tags
}

# The identity reads secrets; whoever runs Terraform writes them.
resource "azurerm_role_assignment" "kv_identity" {
  count = local.enabled ? 1 : 0

  scope                = azurerm_key_vault.netbox[0].id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.netbox[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "kv_deployer" {
  count = local.enabled ? 1 : 0

  scope                = azurerm_key_vault.netbox[0].id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# RBAC takes a while to reach the data plane; writing a secret before it does fails
# with a 403 that reads like a permissions mistake.
resource "time_sleep" "kv_rbac" {
  count = local.enabled ? 1 : 0

  create_duration = "120s"
  depends_on      = [azurerm_role_assignment.kv_deployer]
}

resource "azurerm_key_vault_secret" "secret_key" {
  count = local.enabled ? 1 : 0

  name         = "django-secret-key"
  value        = random_password.secret_key[0].result
  key_vault_id = azurerm_key_vault.netbox[0].id
  tags         = local.tags

  depends_on = [time_sleep.kv_rbac]
}

resource "azurerm_key_vault_secret" "postgres" {
  count = local.enabled ? 1 : 0

  name         = "postgres-password"
  value        = random_password.postgres[0].result
  key_vault_id = azurerm_key_vault.netbox[0].id
  tags         = local.tags

  depends_on = [time_sleep.kv_rbac]
}

resource "azurerm_key_vault_secret" "redis" {
  count = local.enabled ? 1 : 0

  name         = "redis-password"
  value        = azurerm_redis_cache.netbox[0].primary_access_key
  key_vault_id = azurerm_key_vault.netbox[0].id
  tags         = local.tags

  depends_on = [time_sleep.kv_rbac]
}
