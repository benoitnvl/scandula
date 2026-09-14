# Runs against a mocked azurerm: no Azure credentials, nothing real is created,
# so `command = apply` is safe and gives us computed ids to compare.
#
#   make init-local && make test
#
# What the mocks can and can't prove — read this before trusting a green run:
#
#   - azurerm still validates ID *format* on attributes like virtual_hub_id even
#     when mocked, so every referenced type gets a realistic default id.
#   - Mock ids are per resource *type*, and override_resource can't target an
#     instance like region["uks"]. So uks and ukw share ids: per-region wiring is
#     proven through names, locations and prefixes (which differ), never ids.
#   - Resource blocks we need to tell apart get their own override below (the
#     root pool vs the region pools). That id comparison is meaningful.
#
# Every validation in variables.tf has a rejection run at the bottom, and
# `make mutants` proves each one is caught by the validation it's named for, not
# by a neighbour. Add a run alongside any new validation and re-run it — a check
# nobody has seen fail proves nothing.

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
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/networkManagers/avnm-mock/ipamPools/ipam-region" }
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
  mock_resource "azurerm_log_analytics_workspace" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.OperationalInsights/workspaces/log-mock" }
  }
  mock_resource "azurerm_firewall" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/azureFirewalls/afw-mock" }
  }
}

override_resource {
  target = azurerm_network_manager_ipam_pool.root
  values = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/networkManagers/avnm-mock/ipamPools/ipam-root" }
}

variables {
  regions = {
    uks = { location = "uksouth", address_prefix = "10.64.0.0/14", hub_address_prefix = "10.64.0.0/23" }
    ukw = { location = "ukwest", address_prefix = "10.68.0.0/14", hub_address_prefix = "10.68.0.0/23" }
  }
}

# --- the cost guard ----------------------------------------------------------

run "secured_vwan_is_off_by_default" {
  command = apply

  assert {
    condition = (
      length(azurerm_virtual_wan.this) == 0 &&
      length(azurerm_virtual_hub.this) == 0 &&
      length(azurerm_firewall.hub) == 0 &&
      length(azurerm_firewall_policy.this) == 0 &&
      length(azurerm_virtual_hub_routing_intent.this) == 0 &&
      length(azurerm_resource_group.vwan) == 0 &&
      length(azurerm_firewall_policy_rule_collection_group.baseline) == 0
    )
    error_message = "With secured_vwan_enabled unset, nothing billable by the hour may be planned."
  }

  assert {
    condition     = output.virtual_wan_id == null && length(output.virtual_hubs) == 0
    error_message = "Outputs must say plainly that there is no vWAN."
  }

  assert {
    condition = length(azurerm_network_manager_ipam_pool.region) == 2 && alltrue([for k, c in azurerm_network_manager_ipam_pool_static_cidr.hub :
      c.address_prefixes == tolist([var.regions[k].hub_address_prefix]) &&
      c.ipam_pool_id == azurerm_network_manager_ipam_pool.region[k].id &&
      c.ipam_pool_id != azurerm_network_manager_ipam_pool.root.id
    ])
    error_message = "IPAM and the hub reservations must exist even while the hubs are off, reserved on the region pools."
  }
}

# --- what gets built when it's on ---------------------------------------------

run "enabled_builds_a_secured_hub_per_region" {
  command = apply

  variables {
    secured_vwan_enabled = true
  }

  assert {
    condition     = one(azurerm_virtual_wan.this[*].type) == "Standard"
    error_message = "Secured hubs need a Standard vWAN (Basic is site-to-site VPN only)."
  }

  assert {
    condition = length(azurerm_virtual_hub.this) == 2 && alltrue([for k, h in azurerm_virtual_hub.this :
      h.sku == "Standard" &&
      h.location == var.regions[k].location &&
      h.address_prefix == var.regions[k].hub_address_prefix &&
      h.name == "vhub-scandula-${k}" &&
      h.virtual_wan_id == azurerm_virtual_wan.this[0].id
    ])
    error_message = "Each region needs a Standard hub in its own location, on its reserved prefix, in the one vWAN."
  }

  assert {
    condition = length(azurerm_firewall.hub) == 2 && alltrue([for k, f in azurerm_firewall.hub :
      f.sku_name == "AZFW_Hub" &&
      f.sku_tier == "Basic" &&
      f.location == var.regions[k].location &&
      f.name == "afw-scandula-${k}" &&
      f.firewall_policy_id == azurerm_firewall_policy.this[0].id &&
      one(f.virtual_hub).virtual_hub_id == azurerm_virtual_hub.this[k].id
    ])
    error_message = "Each hub needs a Basic hub firewall in its own region, on the shared policy."
  }

  assert {
    condition     = azurerm_firewall_policy.this[0].sku == "Basic"
    error_message = "The policy tier must match the firewall tier."
  }

  # What the firewall allows now lives in tests/firewall.tftest.hcl. With nothing
  # named, there are no rules at all, which is the point.
  assert {
    condition     = length(azurerm_firewall_policy_rule_collection_group.baseline) == 0
    error_message = "With no named flows and no egress destinations, the firewall must have no rules: everything is denied."
  }

  assert {
    condition = length(azurerm_virtual_hub_routing_intent.this) == 2 && alltrue([for k, ri in azurerm_virtual_hub_routing_intent.this :
      ri.virtual_hub_id == azurerm_virtual_hub.this[k].id &&
      toset(flatten([for p in ri.routing_policy : p.destinations])) == toset(["Internet", "PrivateTraffic"]) &&
      alltrue([for p in ri.routing_policy : p.next_hop == azurerm_firewall.hub[k].id])
    ])
    error_message = "Each hub must send both internet and private traffic through its own firewall."
  }

  assert {
    condition     = output.virtual_wan_id != null && toset(keys(output.virtual_hubs)) == toset(["uks", "ukw"])
    error_message = "Outputs should expose the vWAN and one entry per hub."
  }
}

run "one_region_builds_one_hub" {
  command = apply

  variables {
    secured_vwan_enabled = true
    regions = {
      uks = { location = "uksouth", address_prefix = "10.64.0.0/14", hub_address_prefix = "10.64.0.0/23" }
    }
  }

  assert {
    condition     = length(azurerm_virtual_hub.this) == 1 && length(azurerm_firewall.hub) == 1 && length(azurerm_virtual_hub_routing_intent.this) == 1
    error_message = "One region, one secured hub."
  }
}

run "firewall_tier_is_configurable" {
  command = plan

  variables {
    secured_vwan_enabled = true
    firewall_sku_tier    = "Standard"
  }

  assert {
    condition     = azurerm_firewall_policy.this[0].sku == "Standard" && alltrue([for f in azurerm_firewall.hub : f.sku_tier == "Standard"])
    error_message = "firewall_sku_tier should drive both the firewalls and their policy."
  }
}

run "management_group_scope_is_passed_through" {
  command = plan

  variables {
    network_manager_scope = {
      management_group_ids = ["/providers/Microsoft.Management/managementGroups/platform"]
    }
  }

  assert {
    condition     = toset(one(azurerm_network_manager.this.scope).management_group_ids) == toset(["/providers/Microsoft.Management/managementGroups/platform"])
    error_message = "An explicit management-group scope should reach the network manager."
  }
}

run "empty_scope_defaults_to_current_subscription" {
  command = apply

  assert {
    condition     = toset(one(azurerm_network_manager.this.scope).subscription_ids) == toset(["/subscriptions/00000000-0000-0000-0000-000000000000"])
    error_message = "An empty network_manager_scope should default to the current subscription."
  }
}

run "root_static_cidrs_are_reserved_on_the_root_pool" {
  command = apply

  variables {
    root_static_cidrs = { p2s-clients = ["10.79.255.0/24"] }
  }

  assert {
    condition = (
      azurerm_network_manager_ipam_pool_static_cidr.root["p2s-clients"].ipam_pool_id == azurerm_network_manager_ipam_pool.root.id &&
      toset(azurerm_network_manager_ipam_pool_static_cidr.root["p2s-clients"].address_prefixes) == toset(["10.79.255.0/24"])
    )
    error_message = "Static CIDRs should be reserved on the root pool, not a region pool."
  }
}

# --- what gets refused, at plan time ----------------------------------------

run "rejects_a_region_outside_the_root" {
  command = plan
  variables {
    # Must be a *canonical* /14 outside the root. 10.90.0.0/14 has host bits set,
    # so the canonical-form check caught it and this run proved nothing about
    # containment — `make mutants` found that.
    regions = { uks = { location = "uksouth", address_prefix = "10.96.0.0/14", hub_address_prefix = "10.96.0.0/23" } }
  }
  expect_failures = [var.regions]
}

run "rejects_overlapping_regions" {
  command = plan
  variables {
    regions = {
      uks = { location = "uksouth", address_prefix = "10.64.0.0/14", hub_address_prefix = "10.64.0.0/23" }
      ukw = { location = "ukwest", address_prefix = "10.66.0.0/15", hub_address_prefix = "10.66.0.0/23" }
    }
  }
  expect_failures = [var.regions]
}

run "rejects_a_non_canonical_region_prefix" {
  command = plan
  variables {
    regions = { uks = { location = "uksouth", address_prefix = "10.65.0.0/14", hub_address_prefix = "10.64.0.0/23" } }
  }
  expect_failures = [var.regions]
}

run "rejects_a_bad_region_key" {
  command = plan
  variables {
    regions = { UK-South = { location = "uksouth", address_prefix = "10.64.0.0/14", hub_address_prefix = "10.64.0.0/23" } }
  }
  expect_failures = [var.regions]
}

run "rejects_no_regions" {
  command = plan
  variables {
    regions = {}
  }
  expect_failures = [var.regions]
}

run "rejects_a_non_canonical_hub_prefix" {
  command = plan
  variables {
    regions = { uks = { location = "uksouth", address_prefix = "10.64.0.0/14", hub_address_prefix = "10.64.1.0/23" } }
  }
  expect_failures = [var.regions]
}

run "rejects_a_hub_prefix_outside_its_region" {
  command = plan
  variables {
    # inside the root, canonical and /23, but in another region's space
    regions = { uks = { location = "uksouth", address_prefix = "10.64.0.0/14", hub_address_prefix = "10.72.0.0/23" } }
  }
  expect_failures = [var.regions]
}

run "rejects_a_hub_smaller_than_a_24" {
  command = plan
  variables {
    regions = { uks = { location = "uksouth", address_prefix = "10.64.0.0/14", hub_address_prefix = "10.64.0.0/25" } }
  }
  expect_failures = [var.regions]
}

run "rejects_an_unknown_firewall_tier" {
  command = plan
  variables {
    firewall_sku_tier = "Free"
  }
  expect_failures = [var.firewall_sku_tier]
}

run "rejects_a_root_that_overlaps_a_reserved_prefix" {
  command = plan
  variables {
    reserved_prefixes = ["10.1.0.0/23"] # a sample on-prem range; the default is empty
    ipam_root_prefix  = "10.0.0.0/8"
  }
  expect_failures = [var.ipam_root_prefix]
}

run "rejects_a_non_canonical_root" {
  command = plan
  variables {
    ipam_root_prefix = "10.65.0.0/12"
  }
  expect_failures = [var.ipam_root_prefix]
}

run "rejects_an_invalid_reserved_prefix" {
  command = plan
  variables {
    reserved_prefixes = ["10.1.0.0"]
  }
  expect_failures = [var.reserved_prefixes]
}

run "rejects_a_static_cidr_outside_the_root" {
  command = plan
  variables {
    root_static_cidrs = { stray = ["192.168.0.0/24"] }
  }
  expect_failures = [var.root_static_cidrs]
}

run "rejects_a_short_subscription_id" {
  command = plan
  variables {
    network_manager_scope = { subscription_ids = ["00000000-0000-0000-0000-000000000000"] }
  }
  expect_failures = [var.network_manager_scope]
}

run "rejects_a_short_management_group_id" {
  command = plan
  variables {
    network_manager_scope = { management_group_ids = ["platform"] }
  }
  expect_failures = [var.network_manager_scope]
}

run "rejects_a_bad_name_prefix" {
  command = plan
  variables {
    name_prefix = "Scandula_Prod"
  }
  expect_failures = [var.name_prefix]
}

run "rejects_an_unknown_scope_access" {
  command = plan
  variables {
    scope_accesses = ["Connectivity", "Firewall"]
  }
  expect_failures = [var.scope_accesses]
}
