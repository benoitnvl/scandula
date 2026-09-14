# Step 1 of docs/zero-trust.md: without logs, nothing the firewall allows or refuses
# can be verified, and a tightened rule set can't be shown to be safe.
#
# Built only with the hubs, since there's nothing to log otherwise, and can be turned
# off with firewall_diagnostics_enabled. The workspace is free; ingestion and retention
# are not, so log_retention_days keeps it short by default.
#
# log_analytics_destination_type = "Dedicated" puts the logs in the structured AZFW*
# tables rather than one blob of JSON in AzureDiagnostics. The allLogs category group
# keeps working when Azure adds a category, which hand-picked lists don't.

resource "azurerm_log_analytics_workspace" "hub" {
  count = var.secured_vwan_enabled && var.firewall_diagnostics_enabled ? 1 : 0

  name                = "log-${var.name_prefix}-hub"
  resource_group_name = azurerm_resource_group.connectivity.name
  location            = var.location
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days
  tags                = local.tags
}

resource "azurerm_monitor_diagnostic_setting" "firewall" {
  for_each = var.firewall_diagnostics_enabled ? local.vwan_regions : {}

  name                           = "diag-afw-${each.key}"
  target_resource_id             = azurerm_firewall.hub[each.key].id
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.hub[0].id
  log_analytics_destination_type = "Dedicated"

  enabled_log {
    category_group = "allLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}
