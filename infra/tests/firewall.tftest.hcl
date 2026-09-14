# What the hub firewall allows, and where its logs go (docs/zero-trust.md steps 1-2),
# against a mocked azurerm.
#
#   make init-local && make test
#
# What this can't prove: that Azure enforces the rules as written, or that a flow is
# actually blocked. AVNM's reachability analyser or a real packet does that. It pins
# the shape: nothing is allowed unless it's named here, and nothing widens on its own.

mock_provider "azurerm" {
  mock_data "azurerm_subscription" {
    defaults = {
      id              = "/subscriptions/00000000-0000-0000-0000-000000000000"
      subscription_id = "00000000-0000-0000-0000-000000000000"
    }
  }

  mock_resource "azurerm_resource_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock" }
  }
  mock_resource "azurerm_network_manager" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/networkManagers/avnm-mock" }
  }
  mock_resource "azurerm_network_manager_ipam_pool" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/networkManagers/avnm-mock/ipamPools/ipam-mock" }
  }
  mock_resource "azurerm_virtual_wan" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/virtualWans/vwan-mock" }
  }
  mock_resource "azurerm_virtual_hub" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/virtualHubs/vhub-mock" }
  }
  mock_resource "azurerm_firewall_policy" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/firewallPolicies/afwp-mock" }
  }
  mock_resource "azurerm_firewall" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/azureFirewalls/afw-mock" }
  }
  mock_resource "azurerm_log_analytics_workspace" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.OperationalInsights/workspaces/log-mock" }
  }
}

variables {
  secured_vwan_enabled = true
  regions = {
    eas = { location = "eastasia", address_prefix = "10.64.0.0/14", hub_address_prefix = "10.64.0.0/23" }
    sea = { location = "southeastasia", address_prefix = "10.68.0.0/14", hub_address_prefix = "10.68.0.0/23" }
  }
}

# --- deny by default -------------------------------------------------------------------

run "nothing_is_allowed_until_it_is_named" {
  command = apply

  assert {
    condition     = length(azurerm_firewall_policy_rule_collection_group.baseline) == 0
    error_message = "With no named flows and no egress destinations, there must be no rules at all."
  }

  assert {
    condition     = length(output.firewall_rules_named.east_west_flows) == 0 && output.firewall_rules_named.egress_destinations == 0
    error_message = "The output must show that nothing is allowed."
  }
}

run "named_flows_need_the_hubs" {
  command = apply

  variables {
    secured_vwan_enabled = false
    east_west_flows = {
      app-to-sql = { description = "x", sources = ["10.64.1.0/24"], destinations = ["10.68.2.0/24"], protocols = ["TCP"], ports = ["1433"] }
    }
    egress_https_fqdns = ["login.microsoftonline.com"]
  }

  assert {
    condition     = length(azurerm_firewall_policy_rule_collection_group.baseline) == 0 && length(azurerm_firewall_policy.this) == 0
    error_message = "With the cost guard off there is no firewall, so there can be no rules either."
  }
}

# --- east-west: one rule per approved flow ------------------------------------------------

run "a_named_flow_becomes_one_rule" {
  command = apply

  variables {
    east_west_flows = {
      app-to-sql = {
        description  = "app1 (eas) to the SQL MI (sea). Asked for by the app1 team, 2026-09-14."
        sources      = ["10.64.1.0/24"]
        destinations = ["10.68.2.0/24"]
        protocols    = ["TCP"]
        ports        = ["1433"]
      }
    }
  }

  assert {
    condition = (
      length(azurerm_firewall_policy_rule_collection_group.baseline) == 1 &&
      azurerm_firewall_policy_rule_collection_group.baseline[0].firewall_policy_id == azurerm_firewall_policy.this[0].id &&
      azurerm_firewall_policy_rule_collection_group.baseline[0].priority == 1000
    )
    error_message = "The rules must sit on the shared hub policy."
  }

  assert {
    condition = (
      length(azurerm_firewall_policy_rule_collection_group.baseline[0].network_rule_collection) == 1 &&
      one(azurerm_firewall_policy_rule_collection_group.baseline[0].network_rule_collection).name == "allow-named-flows" &&
      one(azurerm_firewall_policy_rule_collection_group.baseline[0].network_rule_collection).action == "Allow" &&
      one(azurerm_firewall_policy_rule_collection_group.baseline[0].network_rule_collection).priority == 1100
    )
    error_message = "Approved flows go in one Allow collection at priority 1100."
  }

  assert {
    condition = anytrue([for r in one(azurerm_firewall_policy_rule_collection_group.baseline[0].network_rule_collection).rule : (
      r.name == "app-to-sql" &&
      toset(r.protocols) == toset(["TCP"]) &&
      toset(r.source_addresses) == toset(["10.64.1.0/24"]) &&
      toset(r.destination_addresses) == toset(["10.68.2.0/24"]) &&
      toset(r.destination_ports) == toset(["1433"])
    )])
    error_message = "The flow must become a rule with exactly the named protocol, ports, source and destination."
  }

  # The old blanket rule allowed the whole root prefix to reach itself.
  assert {
    condition = !anytrue([for r in one(azurerm_firewall_policy_rule_collection_group.baseline[0].network_rule_collection).rule :
      contains(r.source_addresses, var.ipam_root_prefix) || contains(r.destination_addresses, var.ipam_root_prefix) || contains(r.destination_ports, "*")
    ])
    error_message = "No east-west rule may name the whole root prefix or all ports."
  }

  assert {
    condition     = length(azurerm_firewall_policy_rule_collection_group.baseline[0].application_rule_collection) == 0
    error_message = "With no egress destinations there must be no egress rules."
  }
}

# --- egress: an allow-list -----------------------------------------------------------------

run "egress_is_an_allowlist" {
  command = apply

  variables {
    egress_https_fqdns = ["login.microsoftonline.com", "*.ubuntu.com"]
    egress_http_fqdns  = ["ocsp.digicert.com"]
    egress_fqdn_tags   = ["WindowsUpdate"]
  }

  assert {
    condition = (
      length(azurerm_firewall_policy_rule_collection_group.baseline[0].application_rule_collection) == 1 &&
      one(azurerm_firewall_policy_rule_collection_group.baseline[0].application_rule_collection).name == "allow-egress" &&
      one(azurerm_firewall_policy_rule_collection_group.baseline[0].application_rule_collection).action == "Allow" &&
      length(one(azurerm_firewall_policy_rule_collection_group.baseline[0].application_rule_collection).rule) == 3
    )
    error_message = "HTTPS, HTTP and the FQDN tags are three rules in one Allow collection."
  }

  assert {
    condition = anytrue([for r in one(azurerm_firewall_policy_rule_collection_group.baseline[0].application_rule_collection).rule : (
      r.name == "https-allowlist" &&
      toset(r.destination_fqdns) == toset(["login.microsoftonline.com", "*.ubuntu.com"]) &&
      toset([for p in r.protocols : "${p.type}:${p.port}"]) == toset(["Https:443"])
    )])
    error_message = "HTTPS egress must reach the named destinations only, on 443."
  }

  assert {
    condition = anytrue([for r in one(azurerm_firewall_policy_rule_collection_group.baseline[0].application_rule_collection).rule : (
      r.name == "http-revocation" &&
      toset(r.destination_fqdns) == toset(["ocsp.digicert.com"]) &&
      toset([for p in r.protocols : "${p.type}:${p.port}"]) == toset(["Http:80"])
    )])
    error_message = "Plain HTTP must be its own rule, for the named revocation endpoints only."
  }

  assert {
    condition = anytrue([for r in one(azurerm_firewall_policy_rule_collection_group.baseline[0].application_rule_collection).rule :
      r.name == "microsoft-fqdn-tags" && toset(r.destination_fqdn_tags) == toset(["WindowsUpdate"])
    ])
    error_message = "FQDN tags must come through as tags, not as hostnames."
  }

  # No rule may say "anywhere".
  assert {
    condition = alltrue([for r in one(azurerm_firewall_policy_rule_collection_group.baseline[0].application_rule_collection).rule :
      !contains(coalesce(r.destination_fqdns, []), "*") && toset(r.source_addresses) == toset([var.ipam_root_prefix])
    ])
    error_message = "No egress rule may allow any FQDN, and every one is sourced from the root prefix."
  }

  assert {
    condition     = output.firewall_rules_named.egress_destinations == 4
    error_message = "The output must count every named egress destination."
  }

  assert {
    condition     = length(azurerm_firewall_policy_rule_collection_group.baseline[0].nat_rule_collection) == 0
    error_message = "There is no inbound DNAT."
  }
}

run "egress_follows_the_root_prefix" {
  command = plan

  variables {
    ipam_root_prefix   = "10.80.0.0/12"
    regions            = { eas = { location = "eastasia", address_prefix = "10.80.0.0/14", hub_address_prefix = "10.80.0.0/23" } }
    egress_https_fqdns = ["login.microsoftonline.com"]
  }

  assert {
    condition     = toset(one(one(azurerm_firewall_policy_rule_collection_group.baseline[0].application_rule_collection).rule).source_addresses) == toset(["10.80.0.0/12"])
    error_message = "Egress rules must follow ipam_root_prefix, not a hardcoded range."
  }
}

# --- diagnostics ------------------------------------------------------------------------------

run "firewall_logs_reach_a_workspace" {
  command = apply

  assert {
    condition = (
      length(azurerm_log_analytics_workspace.hub) == 1 &&
      azurerm_log_analytics_workspace.hub[0].name == "log-scandula-hub" &&
      azurerm_log_analytics_workspace.hub[0].sku == "PerGB2018" &&
      azurerm_log_analytics_workspace.hub[0].retention_in_days == 30
    )
    error_message = "The hubs need one workspace, with retention set."
  }

  assert {
    condition = (
      toset(keys(azurerm_monitor_diagnostic_setting.firewall)) == toset(["eas", "sea"]) &&
      alltrue([for k, d in azurerm_monitor_diagnostic_setting.firewall :
        d.target_resource_id == azurerm_firewall.hub[k].id &&
        d.log_analytics_workspace_id == azurerm_log_analytics_workspace.hub[0].id
      ])
    )
    error_message = "Every hub firewall must send its logs to that workspace."
  }

  # Structured AZFW* tables, and a category group that survives Azure adding categories.
  assert {
    condition = alltrue([for d in azurerm_monitor_diagnostic_setting.firewall :
      d.log_analytics_destination_type == "Dedicated" &&
      toset([for l in d.enabled_log : l.category_group]) == toset(["allLogs"]) &&
      toset([for m in d.enabled_metric : m.category]) == toset(["AllMetrics"])
    ])
    error_message = "Logs must go to the dedicated tables, as allLogs, with metrics."
  }

  assert {
    condition     = output.firewall_log_analytics_workspace_id == azurerm_log_analytics_workspace.hub[0].id
    error_message = "The workspace must be in the outputs."
  }
}

run "diagnostics_can_be_turned_off" {
  command = apply

  variables {
    firewall_diagnostics_enabled = false
  }

  assert {
    condition     = length(azurerm_log_analytics_workspace.hub) == 0 && length(azurerm_monitor_diagnostic_setting.firewall) == 0
    error_message = "firewall_diagnostics_enabled = false must build no workspace and no settings."
  }

  assert {
    condition     = output.firewall_log_analytics_workspace_id == null
    error_message = "The workspace output must be null when diagnostics are off."
  }
}

run "no_hubs_no_diagnostics" {
  command = apply

  variables {
    secured_vwan_enabled = false
  }

  assert {
    condition     = length(azurerm_log_analytics_workspace.hub) == 0 && length(azurerm_monitor_diagnostic_setting.firewall) == 0
    error_message = "With no hubs there is nothing to log, so nothing billable may be planned."
  }
}

run "log_retention_is_configurable" {
  command = plan

  variables {
    log_retention_days = 90
  }

  assert {
    condition     = azurerm_log_analytics_workspace.hub[0].retention_in_days == 90
    error_message = "log_retention_days must reach the workspace."
  }
}

# --- rejections ------------------------------------------------------------------------------

run "rejects_a_flow_with_any_protocol" {
  command = plan
  variables {
    east_west_flows = { x = { description = "d", sources = ["10.64.1.0/24"], destinations = ["10.64.2.0/24"], protocols = ["Any"], ports = ["443"] } }
  }
  expect_failures = [var.east_west_flows]
}

run "rejects_a_flow_with_all_ports" {
  command = plan
  variables {
    east_west_flows = { x = { description = "d", sources = ["10.64.1.0/24"], destinations = ["10.64.2.0/24"], protocols = ["TCP"], ports = ["*"] } }
  }
  expect_failures = [var.east_west_flows]
}

run "rejects_a_flow_outside_the_root" {
  command = plan
  variables {
    east_west_flows = { x = { description = "d", sources = ["192.168.1.0/24"], destinations = ["10.64.2.0/24"], protocols = ["TCP"], ports = ["443"] } }
  }
  expect_failures = [var.east_west_flows]
}

run "rejects_a_flow_with_nothing_named" {
  command = plan
  variables {
    east_west_flows = { x = { description = "d", sources = ["10.64.1.0/24"], destinations = ["10.64.2.0/24"], protocols = ["TCP"], ports = [] } }
  }
  expect_failures = [var.east_west_flows]
}

run "rejects_a_bad_flow_key" {
  command = plan
  variables {
    east_west_flows = { "App To SQL" = { description = "d", sources = ["10.64.1.0/24"], destinations = ["10.64.2.0/24"], protocols = ["TCP"], ports = ["443"] } }
  }
  expect_failures = [var.east_west_flows]
}

run "rejects_https_to_anywhere" {
  command = plan
  variables {
    egress_https_fqdns = ["*"]
  }
  expect_failures = [var.egress_https_fqdns]
}

run "rejects_http_to_anywhere" {
  command = plan
  variables {
    egress_http_fqdns = ["*"]
  }
  expect_failures = [var.egress_http_fqdns]
}

run "rejects_a_bad_fqdn_tag" {
  command = plan
  variables {
    egress_fqdn_tags = ["Windows Update"]
  }
  expect_failures = [var.egress_fqdn_tags]
}

run "rejects_short_log_retention" {
  command = plan
  variables {
    log_retention_days = 7
  }
  expect_failures = [var.log_retention_days]
}
