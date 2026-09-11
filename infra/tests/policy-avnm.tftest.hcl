# The AVNM allocation policy (policy-avnm.tf), against a mocked azurerm.
#
#   make init-local && make test
#
# What this can't prove: that Azure evaluates the rule the way it reads. It pins the
# rule's exact shape (both count expressions and the alias they count), the pools it
# allows (the region pools, not the root), and the wiring of every assignment. Only a
# real assignment proves the rule, which is why each one starts at Audit.
#
# Each validation on avnm_allocation_policy has a rejection run at the bottom, and
# `make mutants` covers them.

mock_provider "azurerm" {
  mock_data "azurerm_subscription" {
    defaults = {
      id              = "/subscriptions/00000000-0000-0000-0000-000000000000"
      subscription_id = "00000000-0000-0000-0000-000000000000"
    }
  }
  # What sits under mg-landing-zones: mg-corp, and one subscription.
  mock_data "azurerm_management_group" {
    defaults = {
      id                       = "/providers/Microsoft.Management/managementGroups/mg-landing-zones"
      all_management_group_ids = ["/providers/Microsoft.Management/managementGroups/mg-corp"]
      all_subscription_ids     = ["22222222-2222-2222-2222-222222222222"]
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
  mock_resource "azurerm_policy_definition" {
    defaults = { id = "/providers/Microsoft.Management/managementGroups/mg-landing-zones/providers/Microsoft.Authorization/policyDefinitions/scandula-require-avnm-allocation" }
  }
  mock_resource "azurerm_management_group_policy_assignment" {
    defaults = { id = "/providers/Microsoft.Management/managementGroups/mg-corp/providers/Microsoft.Authorization/policyAssignments/avnm-corp" }
  }
  mock_resource "azurerm_subscription_policy_assignment" {
    defaults = { id = "/subscriptions/22222222-2222-2222-2222-222222222222/providers/Microsoft.Authorization/policyAssignments/avnm-app1" }
  }
}

# The root pool gets its own id, so "the root isn't allowed" means something.
override_resource {
  target = azurerm_network_manager_ipam_pool.root
  values = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/networkManagers/avnm-mock/ipamPools/ipam-root" }
}

variables {
  regions = {
    eas = { location = "eastasia", address_prefix = "10.64.0.0/14", hub_address_prefix = "10.64.0.0/23" }
    sea = { location = "southeastasia", address_prefix = "10.68.0.0/14", hub_address_prefix = "10.68.0.0/23" }
  }
}

# --- off by default ------------------------------------------------------------------

run "avnm_policy_is_off_by_default" {
  command = apply

  assert {
    condition = (
      length(azurerm_policy_definition.avnm_allocation) == 0 &&
      length(azurerm_management_group_policy_assignment.avnm_allocation) == 0 &&
      length(azurerm_subscription_policy_assignment.avnm_allocation) == 0
    )
    error_message = "With avnm_allocation_policy unset, no policy may be planned."
  }

  assert {
    condition     = output.avnm_allocation_policy_definition_id == null && length(output.avnm_allocation_policy_assignment_ids) == 0
    error_message = "The outputs must be empty while the policy is off."
  }
}

# Defined now, assigned as scopes migrate.
run "avnm_policy_can_be_defined_without_assignments" {
  command = apply

  variables {
    avnm_allocation_policy = { management_group_id = "/providers/Microsoft.Management/managementGroups/mg-landing-zones" }
  }

  assert {
    condition = (
      azurerm_policy_definition.avnm_allocation[0].management_group_id == "/providers/Microsoft.Management/managementGroups/mg-landing-zones" &&
      length(azurerm_management_group_policy_assignment.avnm_allocation) == 0 &&
      length(azurerm_subscription_policy_assignment.avnm_allocation) == 0
    )
    error_message = "management_group_id alone must create the definition and assign it nowhere."
  }
}

# --- the rule itself -------------------------------------------------------------------

run "avnm_policy_rule_shape" {
  command = apply

  variables {
    avnm_allocation_policy = { management_group_id = "/providers/Microsoft.Management/managementGroups/mg-landing-zones" }
  }

  assert {
    condition     = azurerm_policy_definition.avnm_allocation[0].mode == "All" && azurerm_policy_definition.avnm_allocation[0].policy_type == "Custom"
    error_message = "The definition must be a Custom policy in mode All."
  }

  assert {
    condition     = jsondecode(azurerm_policy_definition.avnm_allocation[0].policy_rule)["if"].allOf[0] == { field = "type", equals = "Microsoft.Network/virtualNetworks" }
    error_message = "The rule must only match VNets."
  }

  # Non-compliant when no allocation comes from an allowed pool...
  assert {
    condition = (
      jsondecode(azurerm_policy_definition.avnm_allocation[0].policy_rule)["if"].allOf[1].anyOf[0].count.field == "Microsoft.Network/virtualNetworks/addressSpace.ipamPoolPrefixAllocations[*]" &&
      jsondecode(azurerm_policy_definition.avnm_allocation[0].policy_rule)["if"].allOf[1].anyOf[0].count.where == { field = "Microsoft.Network/virtualNetworks/addressSpace.ipamPoolPrefixAllocations[*].pool.id", "in" = "[parameters('ipamPoolIds')]" } &&
      jsondecode(azurerm_policy_definition.avnm_allocation[0].policy_rule)["if"].allOf[1].anyOf[0].equals == 0
    )
    error_message = "The rule must flag a VNet with zero allocations from the allowed pools."
  }

  # ...or any allocation comes from another pool.
  assert {
    condition = (
      jsondecode(azurerm_policy_definition.avnm_allocation[0].policy_rule)["if"].allOf[1].anyOf[1].count.field == "Microsoft.Network/virtualNetworks/addressSpace.ipamPoolPrefixAllocations[*]" &&
      jsondecode(azurerm_policy_definition.avnm_allocation[0].policy_rule)["if"].allOf[1].anyOf[1].count.where == { field = "Microsoft.Network/virtualNetworks/addressSpace.ipamPoolPrefixAllocations[*].pool.id", notIn = "[parameters('ipamPoolIds')]" } &&
      jsondecode(azurerm_policy_definition.avnm_allocation[0].policy_rule)["if"].allOf[1].anyOf[1].greater == 0
    )
    error_message = "The rule must flag a VNet with any allocation from a pool that isn't allowed."
  }

  assert {
    condition     = length(jsondecode(azurerm_policy_definition.avnm_allocation[0].policy_rule)["if"].allOf[1].anyOf) == 2
    error_message = "The rule must have exactly those two non-compliance cases."
  }

  assert {
    condition = (
      jsondecode(azurerm_policy_definition.avnm_allocation[0].policy_rule).then.effect == "[parameters('effect')]" &&
      jsondecode(azurerm_policy_definition.avnm_allocation[0].parameters).effect.allowedValues == ["Audit", "Deny"] &&
      jsondecode(azurerm_policy_definition.avnm_allocation[0].parameters).effect.defaultValue == "Audit"
    )
    error_message = "The effect must come from the parameter: Audit or Deny, Audit by default."
  }
}

# --- assignments ------------------------------------------------------------------------

run "avnm_policy_assignments_are_wired" {
  command = apply

  variables {
    avnm_allocation_policy = {
      management_group_id = "/providers/Microsoft.Management/managementGroups/mg-landing-zones"
      assignments = {
        corp = { scope = "/providers/Microsoft.Management/managementGroups/mg-corp" }
        app1 = {
          scope      = "/subscriptions/22222222-2222-2222-2222-222222222222"
          effect     = "Deny"
          not_scopes = ["/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg-databricks-managed"]
        }
      }
    }
  }

  assert {
    condition     = toset(keys(azurerm_management_group_policy_assignment.avnm_allocation)) == toset(["corp"]) && toset(keys(azurerm_subscription_policy_assignment.avnm_allocation)) == toset(["app1"])
    error_message = "A management-group scope must get a management-group assignment, and a subscription scope a subscription one."
  }

  assert {
    condition = (
      azurerm_management_group_policy_assignment.avnm_allocation["corp"].name == "avnm-corp" &&
      azurerm_management_group_policy_assignment.avnm_allocation["corp"].management_group_id == "/providers/Microsoft.Management/managementGroups/mg-corp" &&
      azurerm_management_group_policy_assignment.avnm_allocation["corp"].policy_definition_id == azurerm_policy_definition.avnm_allocation[0].id &&
      azurerm_management_group_policy_assignment.avnm_allocation["corp"].enforce &&
      jsondecode(azurerm_management_group_policy_assignment.avnm_allocation["corp"].parameters).effect.value == "Audit"
    )
    error_message = "The management-group assignment must assign this definition at its scope, enforced, in Audit by default."
  }

  assert {
    condition = (
      azurerm_subscription_policy_assignment.avnm_allocation["app1"].name == "avnm-app1" &&
      azurerm_subscription_policy_assignment.avnm_allocation["app1"].subscription_id == "/subscriptions/22222222-2222-2222-2222-222222222222" &&
      azurerm_subscription_policy_assignment.avnm_allocation["app1"].policy_definition_id == azurerm_policy_definition.avnm_allocation[0].id &&
      azurerm_subscription_policy_assignment.avnm_allocation["app1"].enforce &&
      jsondecode(azurerm_subscription_policy_assignment.avnm_allocation["app1"].parameters).effect.value == "Deny" &&
      azurerm_subscription_policy_assignment.avnm_allocation["app1"].not_scopes == tolist(["/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg-databricks-managed"])
    )
    error_message = "The subscription assignment must carry its own effect and exclusions."
  }

  # Every region pool, and never the root.
  assert {
    condition = alltrue([
      for pools in [
        jsondecode(azurerm_management_group_policy_assignment.avnm_allocation["corp"].parameters).ipamPoolIds.value,
        jsondecode(azurerm_subscription_policy_assignment.avnm_allocation["app1"].parameters).ipamPoolIds.value,
      ] :
      length(pools) == length(var.regions) &&
      alltrue([for id in pools : id == azurerm_network_manager_ipam_pool.region["eas"].id]) &&
      !contains(pools, azurerm_network_manager_ipam_pool.root.id)
    ])
    error_message = "Each assignment must allow every region pool, and not the root pool."
  }

  assert {
    condition     = toset(keys(output.avnm_allocation_policy_assignment_ids)) == toset(["corp", "app1"])
    error_message = "The assignment-ids output must list every assignment."
  }
}

run "avnm_policy_names_fit" {
  command = apply

  variables {
    name_prefix = "abcdefghijklmno"
    avnm_allocation_policy = {
      management_group_id = "/providers/Microsoft.Management/managementGroups/mg-landing-zones"
      assignments = {
        abcdefghijklmnopqrs = { scope = "/providers/Microsoft.Management/managementGroups/mg-corp" }
      }
    }
  }

  assert {
    condition     = length(azurerm_management_group_policy_assignment.avnm_allocation["abcdefghijklmnopqrs"].name) <= 24
    error_message = "A management-group assignment name must be 24 characters or fewer, even with a 19-character key."
  }

  assert {
    condition     = length(azurerm_policy_definition.avnm_allocation[0].name) <= 64
    error_message = "A policy definition name must be 64 characters or fewer, even with a 15-character name_prefix."
  }
}

# --- where it may be assigned ------------------------------------------------------------

run "avnm_assignment_at_the_definitions_own_mg_is_allowed" {
  command = plan

  variables {
    avnm_allocation_policy = {
      management_group_id = "/providers/Microsoft.Management/managementGroups/mg-landing-zones"
      assignments         = { lz = { scope = "/providers/Microsoft.Management/managementGroups/mg-landing-zones" } }
    }
  }

  assert {
    condition     = length(azurerm_management_group_policy_assignment.avnm_allocation) == 1
    error_message = "The definition's own management group must be an allowed scope."
  }
}

# The provider's lists may hold bare names rather than full ids: both must work.
run "avnm_hierarchy_check_accepts_bare_names" {
  command = plan

  override_data {
    target = data.azurerm_management_group.avnm_policy
    values = {
      all_management_group_ids = ["MG-Corp"]
      all_subscription_ids     = ["/subscriptions/22222222-2222-2222-2222-222222222222"]
    }
  }

  variables {
    avnm_allocation_policy = {
      management_group_id = "/providers/Microsoft.Management/managementGroups/mg-landing-zones"
      assignments = {
        corp = { scope = "/providers/Microsoft.Management/managementGroups/mg-corp" }
        app1 = { scope = "/subscriptions/22222222-2222-2222-2222-222222222222" }
      }
    }
  }

  assert {
    condition     = length(azurerm_management_group_policy_assignment.avnm_allocation) == 1 && length(azurerm_subscription_policy_assignment.avnm_allocation) == 1
    error_message = "Scopes under the management group must pass however the provider formats its lists."
  }
}

run "refuses_an_avnm_mg_outside_the_hierarchy" {
  command = plan

  variables {
    avnm_allocation_policy = {
      management_group_id = "/providers/Microsoft.Management/managementGroups/mg-landing-zones"
      assignments         = { other = { scope = "/providers/Microsoft.Management/managementGroups/mg-somewhere-else" } }
    }
  }

  expect_failures = [azurerm_management_group_policy_assignment.avnm_allocation]
}

run "refuses_an_avnm_subscription_outside_the_hierarchy" {
  command = plan

  variables {
    avnm_allocation_policy = {
      management_group_id = "/providers/Microsoft.Management/managementGroups/mg-landing-zones"
      assignments         = { other = { scope = "/subscriptions/33333333-3333-3333-3333-333333333333" } }
    }
  }

  expect_failures = [azurerm_subscription_policy_assignment.avnm_allocation]
}

# --- rejections ---------------------------------------------------------------------------

run "rejects_a_short_avnm_policy_management_group_id" {
  command = plan
  variables {
    avnm_allocation_policy = { management_group_id = "mg-landing-zones" }
  }
  expect_failures = [var.avnm_allocation_policy]
}

run "rejects_avnm_assignments_without_a_definition" {
  command = plan
  variables {
    avnm_allocation_policy = {
      assignments = { corp = { scope = "/providers/Microsoft.Management/managementGroups/mg-corp" } }
    }
  }
  expect_failures = [var.avnm_allocation_policy]
}

run "rejects_an_avnm_assignment_at_a_resource_group" {
  command = plan
  variables {
    avnm_allocation_policy = {
      management_group_id = "/providers/Microsoft.Management/managementGroups/mg-landing-zones"
      assignments         = { app1 = { scope = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg-app1" } }
    }
  }
  expect_failures = [var.avnm_allocation_policy]
}

run "rejects_an_unknown_avnm_effect" {
  command = plan
  variables {
    avnm_allocation_policy = {
      management_group_id = "/providers/Microsoft.Management/managementGroups/mg-landing-zones"
      assignments         = { corp = { scope = "/providers/Microsoft.Management/managementGroups/mg-corp", effect = "Disabled" } }
    }
  }
  expect_failures = [var.avnm_allocation_policy]
}

run "rejects_a_bad_avnm_assignment_key" {
  command = plan
  variables {
    avnm_allocation_policy = {
      management_group_id = "/providers/Microsoft.Management/managementGroups/mg-landing-zones"
      assignments         = { Corp_Landing = { scope = "/providers/Microsoft.Management/managementGroups/mg-corp" } }
    }
  }
  expect_failures = [var.avnm_allocation_policy]
}
