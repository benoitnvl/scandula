# Diagnostics to the workspace, as upstream's modules send them. Logs as the
# allLogs category group rather than upstream's hand-picked categories: a superset,
# and it doesn't break when a category is renamed.
locals {
  diagnostic_targets = merge(
    { for r in azurerm_key_vault.ipam : "key-vault" => { id = r.id, logs = true, dedicated = false } },
    { for r in azurerm_cosmosdb_account.ipam : "cosmos" => { id = r.id, logs = true, dedicated = true } },
    { for r in azurerm_service_plan.ipam : "service-plan" => { id = r.id, logs = false, dedicated = false } },
    { for r in azurerm_linux_web_app.ipam : "web-app" => { id = r.id, logs = true, dedicated = false } },
  )
}

resource "azurerm_monitor_diagnostic_setting" "ipam" {
  for_each = local.diagnostic_targets

  name                           = "diag-${each.key}"
  target_resource_id             = each.value.id
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.ipam[0].id
  log_analytics_destination_type = each.value.dedicated ? "Dedicated" : null

  dynamic "enabled_log" {
    for_each = each.value.logs ? ["allLogs"] : []
    content {
      category_group = enabled_log.value
    }
  }

  enabled_metric {
    category = "AllMetrics"
  }
}
