# The on-premises overlap policy (policy-onprem.tf), against a mocked azurerm.
#
#   make init-local && make test
#
# What this can't prove: that Azure evaluates the rule the way it reads. It pins the
# wiring and the rule's exact expressions, including the same-family guard that
# stops a dual-stack VNet from failing evaluation (which Azure treats as a deny).
# Only a real assignment proves the rule, which is why the effect starts at Audit.
#
# Each validation on onprem_policy has a rejection run at the bottom, and
# `make mutants` covers them like the ones in connectivity.tftest.hcl.

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
  mock_resource "azurerm_policy_definition" {
    defaults = { id = "/providers/Microsoft.Management/managementGroups/mg-landing-zones/providers/Microsoft.Authorization/policyDefinitions/scandula-deny-onprem-overlap" }
  }
  mock_resource "azurerm_management_group_policy_assignment" {
    defaults = { id = "/providers/Microsoft.Management/managementGroups/mg-landing-zones/providers/Microsoft.Authorization/policyAssignments/scandula-onprem" }
  }
}

variables {
  regions = {
    eas = { location = "eastasia", address_prefix = "10.64.0.0/14", hub_address_prefix = "10.64.0.0/23" }
  }
  reserved_prefixes = ["192.168.0.0/16", "172.16.0.0/12"]
}

# --- off by default ------------------------------------------------------------

run "onprem_policy_is_off_by_default" {
  command = apply

  assert {
    condition     = length(azurerm_policy_definition.onprem_overlap) == 0 && length(azurerm_management_group_policy_assignment.onprem_overlap) == 0
    error_message = "With onprem_policy.management_group_id unset, no policy may be planned: it reaches far beyond this repo."
  }

  assert {
    condition     = output.onprem_policy_assignment_id == null
    error_message = "The assignment output must be null while the policy is off."
  }
}

# --- on: wiring ----------------------------------------------------------------

run "onprem_policy_audits_by_default" {
  command = apply

  variables {
    onprem_policy = { management_group_id = "/providers/Microsoft.Management/managementGroups/mg-landing-zones" }
  }

  assert {
    condition = (
      azurerm_policy_definition.onprem_overlap[0].management_group_id == "/providers/Microsoft.Management/managementGroups/mg-landing-zones" &&
      azurerm_management_group_policy_assignment.onprem_overlap[0].management_group_id == "/providers/Microsoft.Management/managementGroups/mg-landing-zones"
    )
    error_message = "The definition and its assignment must both live at onprem_policy.management_group_id."
  }

  assert {
    condition     = azurerm_management_group_policy_assignment.onprem_overlap[0].policy_definition_id == azurerm_policy_definition.onprem_overlap[0].id
    error_message = "The assignment must assign this definition."
  }

  assert {
    condition     = jsondecode(azurerm_management_group_policy_assignment.onprem_overlap[0].parameters).effect.value == "Audit"
    error_message = "The effect must default to Audit."
  }

  assert {
    condition     = jsondecode(azurerm_management_group_policy_assignment.onprem_overlap[0].parameters).onPremRanges.value == ["192.168.0.0/16", "172.16.0.0/12"]
    error_message = "The assignment must pass reserved_prefixes as onPremRanges."
  }

  assert {
    condition     = azurerm_management_group_policy_assignment.onprem_overlap[0].enforce
    error_message = "The assignment must be enforced; Audit vs Deny is the effect's job."
  }

  assert {
    condition     = output.onprem_policy_assignment_id == azurerm_management_group_policy_assignment.onprem_overlap[0].id
    error_message = "The output must expose the assignment id."
  }
}

# --- on: the rule itself -------------------------------------------------------

run "onprem_policy_rule_shape" {
  command = apply

  variables {
    onprem_policy = { management_group_id = "/providers/Microsoft.Management/managementGroups/mg-landing-zones" }
  }

  assert {
    condition     = azurerm_policy_definition.onprem_overlap[0].mode == "All" && azurerm_policy_definition.onprem_overlap[0].policy_type == "Custom"
    error_message = "The definition must be a Custom policy in mode All."
  }

  assert {
    condition     = jsondecode(azurerm_policy_definition.onprem_overlap[0].policy_rule)["if"].allOf[0] == { field = "type", equals = "Microsoft.Network/virtualNetworks" }
    error_message = "The rule must only match VNets."
  }

  assert {
    condition     = jsondecode(azurerm_policy_definition.onprem_overlap[0].policy_rule)["if"].allOf[1].count.field == "Microsoft.Network/virtualNetworks/addressSpace.addressPrefixes[*]"
    error_message = "The rule must look at every prefix of the VNet's address space."
  }

  assert {
    condition = (
      jsondecode(azurerm_policy_definition.onprem_overlap[0].policy_rule)["if"].allOf[1].count.where.count.value == "[parameters('onPremRanges')]" &&
      jsondecode(azurerm_policy_definition.onprem_overlap[0].policy_rule)["if"].allOf[1].count.where.count.name == "onPremRange"
    )
    error_message = "The rule must loop over the onPremRanges parameter as onPremRange."
  }

  # Both directions of overlap, each guarded so mixed address families never reach
  # ipRangeContains. Pinned exactly: a loosened guard is a blocked dual-stack VNet.
  assert {
    condition = [for c in jsondecode(azurerm_policy_definition.onprem_overlap[0].policy_rule)["if"].allOf[1].count.where.count.where.anyOf : c.value] == [
      "[if(equals(contains(current('Microsoft.Network/virtualNetworks/addressSpace.addressPrefixes[*]'), ':'), contains(current('onPremRange'), ':')), ipRangeContains(current('onPremRange'), current('Microsoft.Network/virtualNetworks/addressSpace.addressPrefixes[*]')), false)]",
      "[if(equals(contains(current('Microsoft.Network/virtualNetworks/addressSpace.addressPrefixes[*]'), ':'), contains(current('onPremRange'), ':')), ipRangeContains(current('Microsoft.Network/virtualNetworks/addressSpace.addressPrefixes[*]'), current('onPremRange')), false)]",
    ]
    error_message = "The rule must test both directions of overlap, each behind the same-family guard."
  }

  assert {
    condition     = jsondecode(azurerm_policy_definition.onprem_overlap[0].policy_rule).then.effect == "[parameters('effect')]"
    error_message = "The rule's effect must come from the effect parameter."
  }

  assert {
    condition     = jsondecode(azurerm_policy_definition.onprem_overlap[0].parameters).effect.allowedValues == ["Audit", "Deny"]
    error_message = "The definition must only allow Audit or Deny."
  }
}

run "onprem_policy_passes_deny_through" {
  command = apply

  variables {
    onprem_policy = { management_group_id = "/providers/Microsoft.Management/managementGroups/mg-landing-zones", effect = "Deny" }
  }

  assert {
    condition     = jsondecode(azurerm_management_group_policy_assignment.onprem_overlap[0].parameters).effect.value == "Deny"
    error_message = "effect = Deny must reach the assignment."
  }
}

run "onprem_policy_canonicalises_ranges" {
  command = apply

  variables {
    reserved_prefixes = ["192.168.1.7/16"]
    onprem_policy     = { management_group_id = "/providers/Microsoft.Management/managementGroups/mg-landing-zones" }
  }

  assert {
    condition     = jsondecode(azurerm_management_group_policy_assignment.onprem_overlap[0].parameters).onPremRanges.value == ["192.168.0.0/16"]
    error_message = "Ranges must reach the policy in canonical form (host bits cleared)."
  }
}

# azurerm itself rejects an assignment name over 24 characters at plan, so a name
# too long for the default prefix already fails the runs above. This run is for a
# name that fits "scandula" but not the longest name_prefix allowed (15).
run "onprem_policy_names_fit_the_longest_prefix" {
  command = apply

  variables {
    name_prefix   = "abcdefghijklmno"
    onprem_policy = { management_group_id = "/providers/Microsoft.Management/managementGroups/mg-landing-zones" }
  }

  assert {
    condition     = length(azurerm_management_group_policy_assignment.onprem_overlap[0].name) <= 24
    error_message = "A management-group assignment name must be 24 characters or fewer, even with a 15-character name_prefix."
  }

  assert {
    condition     = length(azurerm_policy_definition.onprem_overlap[0].name) <= 64
    error_message = "A policy definition name must be 64 characters or fewer."
  }
}

# --- rejections ----------------------------------------------------------------

run "rejects_a_short_policy_management_group_id" {
  command = plan
  variables {
    onprem_policy = { management_group_id = "mg-landing-zones" }
  }
  expect_failures = [var.onprem_policy]
}

run "rejects_an_unknown_policy_effect" {
  command = plan
  variables {
    onprem_policy = { management_group_id = "/providers/Microsoft.Management/managementGroups/mg-landing-zones", effect = "Disabled" }
  }
  expect_failures = [var.onprem_policy]
}

run "rejects_the_policy_with_no_ranges" {
  command = plan
  variables {
    reserved_prefixes = []
    onprem_policy     = { management_group_id = "/providers/Microsoft.Management/managementGroups/mg-landing-zones" }
  }
  expect_failures = [var.onprem_policy]
}

run "rejects_the_policy_with_over_100_ranges" {
  command = plan
  variables {
    reserved_prefixes = [for i in range(101) : format("192.168.%d.0/24", i)]
    onprem_policy     = { management_group_id = "/providers/Microsoft.Management/managementGroups/mg-landing-zones" }
  }
  expect_failures = [var.onprem_policy]
}
