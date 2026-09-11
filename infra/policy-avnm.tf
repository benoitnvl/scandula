# Layer B of docs/azure-ipam-plan.md: in a migrated scope, every VNet must take its
# address space from AVNM IPAM, from one of this repo's region pools. IPAM never
# hands out overlapping prefixes, so a VNet that has to hold an allocation can't
# overlap another one. This is Microsoft's pattern ("Prevent overlapping virtual
# network address spaces with Azure Policy and IPAM"), written as count expressions.
#
# Assign it only where every VNet is already under AVNM: to each subscription or
# management group as it migrates. Never assign it at the landing-zone root while VNets
# outside AVNM still live there: under Deny, every update to them would be refused.
#
# Off until avnm_allocation_policy.management_group_id is set, which creates the
# definition. Each entry in avnm_allocation_policy.assignments assigns it to one
# migrated scope (variables.tf).
#
# A VNet is non-compliant if it holds no allocation from a region pool, or holds
# one from any other pool (another network manager's, say).
#   - Count expressions, not the bare [*] conditions in Microsoft's sample. Azure
#     Policy's array docs say a [*] condition over an empty (or missing) array is true,
#     "because no member of the array is in violation", and recommend count instead.
#     So the sample never flags a VNet with no allocation at all, which is exactly the
#     VNet it's meant to stop. [*] conditions are also ANDed across members, so the
#     sample would flag a VNet with allocations from two allowed pools.
#   - Allocations only. Not checked: a static addressPrefixes entry next to an
#     allocation (it isn't verified whether Azure accepts that mix). Layer A
#     (policy-onprem.tf) still keeps on-premises ranges out either way.
#   - The region pools, not the root: spokes allocate from their region's pool.
#   - vWAN hubs and their firewalls aren't VNets, so this never touches them.

locals {
  avnm_allocation      = "Microsoft.Network/virtualNetworks/addressSpace.ipamPoolPrefixAllocations[*]"
  avnm_region_pool_ids = [for pool in azurerm_network_manager_ipam_pool.region : pool.id]

  avnm_mg_assignments           = { for k, a in var.avnm_allocation_policy.assignments : k => a if startswith(a.scope, "/providers/Microsoft.Management/managementGroups/") }
  avnm_subscription_assignments = { for k, a in var.avnm_allocation_policy.assignments : k => a if startswith(a.scope, "/subscriptions/") }

  avnm_non_compliance_message = "This VNet must take its address space from AVNM IPAM (an allocation from one of scandula's region pools), not from static address prefixes."
}

# --- where it may be assigned ------------------------------------------------------------

# A definition can only be assigned at its own management group or below it. Checked
# at plan against the real hierarchy, rather than failing halfway through an apply.
# Needs read access to that management group (Resource Policy Contributor has it).
data "azurerm_management_group" "avnm_policy" {
  count = var.avnm_allocation_policy.management_group_id != null && length(var.avnm_allocation_policy.assignments) > 0 ? 1 : 0

  name = basename(var.avnm_allocation_policy.management_group_id)
}

locals {
  # Compared by name (the last path segment, lower-cased), so it works whether the
  # provider lists full ids or bare names.
  avnm_allowed_management_groups = toset([
    for id in concat(compact([var.avnm_allocation_policy.management_group_id]), try(data.azurerm_management_group.avnm_policy[0].all_management_group_ids, [])) :
    lower(basename(id))
  ])
  avnm_allowed_subscriptions = toset([
    for id in try(data.azurerm_management_group.avnm_policy[0].all_subscription_ids, []) : lower(basename(id))
  ])
}

# --- the definition -----------------------------------------------------------------------

resource "azurerm_policy_definition" "avnm_allocation" {
  count = var.avnm_allocation_policy.management_group_id != null ? 1 : 0

  name                = "${var.name_prefix}-require-avnm-allocation"
  display_name        = "VNets must take their address space from AVNM IPAM"
  description         = "Flags (Audit) or refuses (Deny) any VNet without an IPAM allocation from the allowed AVNM pools, or with one from any other pool. Managed from benoitnvl/scandula (infra/policy-avnm.tf)."
  policy_type         = "Custom"
  mode                = "All"
  management_group_id = var.avnm_allocation_policy.management_group_id

  parameters = jsonencode({
    ipamPoolIds = {
      type     = "Array"
      metadata = { displayName = "Allowed IPAM pools", description = "Resource ids of the AVNM IPAM pools VNets must allocate from." }
    }
    effect = {
      type          = "String"
      allowedValues = ["Audit", "Deny"]
      defaultValue  = "Audit"
      metadata      = { displayName = "Effect" }
    }
  })

  policy_rule = jsonencode({
    "if" = {
      allOf = [
        { field = "type", equals = "Microsoft.Network/virtualNetworks" },
        {
          anyOf = [
            # No allocation from an allowed pool: static prefixes, or nothing at all.
            {
              count = {
                field = local.avnm_allocation
                where = { field = "${local.avnm_allocation}.pool.id", "in" = "[parameters('ipamPoolIds')]" }
              }
              equals = 0
            },
            # An allocation from a pool that isn't allowed.
            {
              count = {
                field = local.avnm_allocation
                where = { field = "${local.avnm_allocation}.pool.id", notIn = "[parameters('ipamPoolIds')]" }
              }
              greater = 0
            },
          ]
        },
      ]
    }
    then = { effect = "[parameters('effect')]" }
  })
}

# --- assignments, one per migrated scope ----------------------------------------------

resource "azurerm_management_group_policy_assignment" "avnm_allocation" {
  for_each = local.avnm_mg_assignments

  name                 = "avnm-${each.key}"
  display_name         = "VNets must take their address space from AVNM IPAM (${each.key})"
  description          = "Layer B for a migrated scope. Managed from benoitnvl/scandula (infra/policy-avnm.tf)."
  management_group_id  = each.value.scope
  policy_definition_id = azurerm_policy_definition.avnm_allocation[0].id
  not_scopes           = each.value.not_scopes
  enforce              = true

  parameters = jsonencode({
    ipamPoolIds = { value = local.avnm_region_pool_ids }
    effect      = { value = each.value.effect }
  })

  non_compliance_message {
    content = local.avnm_non_compliance_message
  }

  lifecycle {
    precondition {
      condition     = contains(local.avnm_allowed_management_groups, lower(basename(each.value.scope)))
      error_message = "avnm_allocation_policy assignment \"${each.key}\": ${each.value.scope} isn't avnm_allocation_policy.management_group_id or a management group under it, so the definition can't be assigned there."
    }
  }
}

resource "azurerm_subscription_policy_assignment" "avnm_allocation" {
  for_each = local.avnm_subscription_assignments

  name                 = "avnm-${each.key}"
  display_name         = "VNets must take their address space from AVNM IPAM (${each.key})"
  description          = "Layer B for a migrated scope. Managed from benoitnvl/scandula (infra/policy-avnm.tf)."
  subscription_id      = each.value.scope
  policy_definition_id = azurerm_policy_definition.avnm_allocation[0].id
  not_scopes           = each.value.not_scopes
  enforce              = true

  parameters = jsonencode({
    ipamPoolIds = { value = local.avnm_region_pool_ids }
    effect      = { value = each.value.effect }
  })

  non_compliance_message {
    content = local.avnm_non_compliance_message
  }

  lifecycle {
    precondition {
      condition     = contains(local.avnm_allowed_subscriptions, lower(basename(each.value.scope)))
      error_message = "avnm_allocation_policy assignment \"${each.key}\": ${each.value.scope} isn't a subscription under avnm_allocation_policy.management_group_id, so the definition can't be assigned there."
    }
  }
}
