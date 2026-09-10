# Two kinds of connectivity configuration:
#
#   cc-hubspoke-<region>  hub-and-spoke: the region's hub peers with every member
#                         of ng-spokes-<region>. Spokes don't talk to each other
#                         directly — that traffic goes through the hub.
#   cc-hub-mesh           the hubs themselves, in a global mesh (only when there's
#                         more than one region).
#
# A configuration does nothing until it's committed by a deployment, and
# deployments are per region — see azurerm_network_manager_deployment below.

# Spokes join from the repos that own them (a static member, or Azure Policy
# for tag-based membership). This repo only creates the group.
resource "azurerm_network_manager_network_group" "spokes" {
  for_each = var.regions

  name               = "ng-spokes-${each.key}"
  network_manager_id = azurerm_network_manager.this.id
  description        = "Spoke VNets in ${each.value.location}. Members are added where the spokes live, not here."
}

resource "azurerm_network_manager_connectivity_configuration" "hub_and_spoke" {
  for_each = var.regions

  name                  = "cc-hubspoke-${each.key}"
  network_manager_id    = azurerm_network_manager.this.id
  connectivity_topology = "HubAndSpoke"
  description           = "Hub ${each.key} and the spokes in ng-spokes-${each.key}."

  applies_to_group {
    group_connectivity = "None"
    network_group_id   = azurerm_network_manager_network_group.spokes[each.key].id
    use_hub_gateway    = each.value.use_hub_gateway
  }

  hub {
    resource_id   = azurerm_virtual_network.hub[each.key].id
    resource_type = "Microsoft.Network/virtualNetworks"
  }
}

resource "azurerm_network_manager_network_group" "hubs" {
  count = local.hub_mesh ? 1 : 0

  name               = "ng-hubs"
  network_manager_id = azurerm_network_manager.this.id
  description        = "Every regional hub VNet, meshed together by cc-hub-mesh."
}

resource "azurerm_network_manager_static_member" "hub" {
  for_each = local.hub_mesh ? var.regions : {}

  name                      = "hub-${each.key}"
  network_group_id          = azurerm_network_manager_network_group.hubs[0].id
  target_virtual_network_id = azurerm_virtual_network.hub[each.key].id
}

resource "azurerm_network_manager_connectivity_configuration" "hub_mesh" {
  count = local.hub_mesh ? 1 : 0

  name                  = "cc-hub-mesh"
  network_manager_id    = azurerm_network_manager.this.id
  connectivity_topology = "Mesh"
  global_mesh_enabled   = true
  description           = "Hub-to-hub, across regions."

  applies_to_group {
    group_connectivity  = "DirectlyConnected"
    network_group_id    = azurerm_network_manager_network_group.hubs[0].id
    global_mesh_enabled = true
  }
}

# One deployment per hub region. It commits, for that region, exactly the
# configurations listed — so it carries the region's hub-and-spoke plus the mesh.
#
# ⚠ Destroying a deployment un-commits its configurations: the peerings AVNM
# created in that region go away. Removing a region from var.regions does that
# to the region (intended); anything else that plans a destroy here is not.
resource "azurerm_network_manager_deployment" "connectivity" {
  for_each = var.regions

  network_manager_id = azurerm_network_manager.this.id
  location           = each.value.location
  scope_access       = "Connectivity"
  configuration_ids = concat(
    [azurerm_network_manager_connectivity_configuration.hub_and_spoke[each.key].id],
    azurerm_network_manager_connectivity_configuration.hub_mesh[*].id,
  )

  # Editing a configuration in place doesn't change configuration_ids, and AVNM
  # only enforces what was last committed. Fold what shapes the configuration
  # in here so an edit shows up as a re-commit in the plan.
  triggers = {
    hub             = azurerm_virtual_network.hub[each.key].id
    use_hub_gateway = tostring(each.value.use_hub_gateway)
  }

  depends_on = [azurerm_network_manager_static_member.hub]
}
