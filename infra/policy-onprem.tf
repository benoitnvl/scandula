# Layer A of docs/azure-ipam-plan.md: no VNet under the chosen management group may
# overlap an on-premises range (reserved_prefixes), in either direction. Reserving a
# range in IPAM only stops IPAM handing it out; this stops everyone, in every
# subscription under the management group. Off until onprem_policy.management_group_id
# is set (variables.tf).
#
# What it covers:
#   - VNet creates and updates, and the compliance scan of existing VNets. A subnet
#     always sits inside its VNet's address space, so subnets are covered too.
#   - A VNet that takes its space from an AVNM IPAM pool sends no addressPrefixes in
#     its request, so only the scan sees it. That's safe: the root pool can't overlap
#     reserved_prefixes (variables.tf).
#   - Resources that name on-premises ranges on purpose, like local network gateways,
#     are other types and aren't touched.
#
# ⚠ ipRangeContains fails when the two ranges are different address families, and
# Azure Policy treats a failed evaluation as a deny, even under Audit. Every
# comparison is therefore wrapped in if() and only made between ranges of the same
# family. Azure Policy documents if() as evaluating only the branch it picks, for
# exactly this purpose. Without the guard, every dual-stack VNet would be blocked.

locals {
  onprem_policy_enabled = var.onprem_policy.management_group_id != null

  # ARM expressions for the two elements being compared: a prefix of the VNet (the
  # field count's element) and an on-premises range (the value count's).
  vnet_prefix  = "current('Microsoft.Network/virtualNetworks/addressSpace.addressPrefixes[*]')"
  onprem_range = "current('onPremRange')"
  same_family  = "equals(contains(${local.vnet_prefix}, ':'), contains(${local.onprem_range}, ':'))"
}

resource "azurerm_policy_definition" "onprem_overlap" {
  count = local.onprem_policy_enabled ? 1 : 0

  name                = "${var.name_prefix}-deny-onprem-overlap"
  display_name        = "VNets must not overlap on-premises ranges"
  description         = "Flags (Audit) or refuses (Deny) any VNet whose address space overlaps an on-premises range, in either direction. Managed from benoitnvl/scandula (infra/policy-onprem.tf)."
  policy_type         = "Custom"
  mode                = "All"
  management_group_id = var.onprem_policy.management_group_id

  parameters = jsonencode({
    onPremRanges = {
      type     = "Array"
      metadata = { displayName = "On-premises ranges", description = "CIDRs in use on-premises. No VNet may overlap them." }
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
          # Any prefix of the VNet ...
          count = {
            field = "Microsoft.Network/virtualNetworks/addressSpace.addressPrefixes[*]"
            where = {
              # ... that overlaps any on-premises range: one contains the other.
              count = {
                value = "[parameters('onPremRanges')]"
                name  = "onPremRange"
                where = {
                  anyOf = [
                    { value = "[if(${local.same_family}, ipRangeContains(${local.onprem_range}, ${local.vnet_prefix}), false)]", equals = true },
                    { value = "[if(${local.same_family}, ipRangeContains(${local.vnet_prefix}, ${local.onprem_range}), false)]", equals = true },
                  ]
                }
              }
              greater = 0
            }
          }
          greater = 0
        },
      ]
    }
    then = { effect = "[parameters('effect')]" }
  })
}

resource "azurerm_management_group_policy_assignment" "onprem_overlap" {
  count = local.onprem_policy_enabled ? 1 : 0

  # Management-group assignment names are 24 characters at most; name_prefix is 15.
  name                 = "${var.name_prefix}-onprem"
  display_name         = "VNets must not overlap on-premises ranges"
  description          = "On-premises ranges from scandula's reserved_prefixes. Managed from benoitnvl/scandula (infra/policy-onprem.tf)."
  management_group_id  = var.onprem_policy.management_group_id
  policy_definition_id = azurerm_policy_definition.onprem_overlap[0].id
  enforce              = true

  parameters = jsonencode({
    onPremRanges = { value = [for r in var.reserved_prefixes : cidrsubnet(r, 0, 0)] }
    effect       = { value = var.onprem_policy.effect }
  })

  non_compliance_message {
    content = "This VNet's address space overlaps an on-premises range. Take a range from the AVNM pool for your region instead."
  }
}
