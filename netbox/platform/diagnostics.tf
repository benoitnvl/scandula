# The workspace the container environment and the database log to. NetBox is the
# record of who changed the address plan; its own logs are how you find out what
# happened to the thing holding that record.

resource "azurerm_log_analytics_workspace" "netbox" {
  count = local.enabled ? 1 : 0

  name                = local.names.log_analytics
  resource_group_name = azurerm_resource_group.netbox[0].name
  location            = var.location
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days
  tags                = local.tags
}

resource "azurerm_monitor_diagnostic_setting" "postgres" {
  count = local.enabled ? 1 : 0

  name                           = "netbox-postgres"
  target_resource_id             = azurerm_postgresql_flexible_server.netbox[0].id
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.netbox[0].id
  log_analytics_destination_type = "Dedicated"

  enabled_log {
    category_group = "allLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

resource "azurerm_monitor_diagnostic_setting" "key_vault" {
  count = local.enabled ? 1 : 0

  name                       = "netbox-key-vault"
  target_resource_id         = azurerm_key_vault.netbox[0].id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.netbox[0].id

  enabled_log {
    category_group = "audit"
  }
}
