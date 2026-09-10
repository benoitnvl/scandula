# Runs against a mocked azurerm: no Azure credentials, nothing real is created,
# so `command = apply` is safe and gives us computed ids to compare.
#
#   make init-local && make test
#
# What the mocks can and can't prove — read this before trusting a green run:
#
#   - azurerm still validates ID *format* on attributes like network_manager_id
#     even when mocked, so every referenced type gets a realistic default id.
#   - Mock ids are per resource *type*, and override_resource can't target an
#     instance like region["uks"]. So uks and ukw share ids: per-region wiring
#     is proven through names and locations (which differ), never through ids.
#   - Resource blocks we need to tell apart get their own override below: the
#     root pool vs the region pools, the hub mesh vs the hub-and-spoke configs,
#     ng-hubs vs the spoke groups. Those id comparisons are meaningful.
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
  mock_resource "azurerm_network_manager_network_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/networkManagers/avnm-mock/networkGroups/ng-spokes" }
  }
  mock_resource "azurerm_network_manager_connectivity_configuration" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/networkManagers/avnm-mock/connectivityConfigurations/cc-hubspoke" }
  }
  mock_resource "azurerm_virtual_network" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/virtualNetworks/vnet-hub" }
  }
  mock_resource "azurerm_subnet" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/virtualNetworks/vnet-hub/subnets/snet" }
  }
}

override_resource {
  target = azurerm_network_manager_ipam_pool.root
  values = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/networkManagers/avnm-mock/ipamPools/ipam-root" }
}

override_resource {
  target = azurerm_network_manager_network_group.hubs
  values = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/networkManagers/avnm-mock/networkGroups/ng-hubs" }
}

override_resource {
  target = azurerm_network_manager_connectivity_configuration.hub_mesh
  values = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/networkManagers/avnm-mock/connectivityConfigurations/cc-hub-mesh" }
}

variables {
  regions = {
    uks = { location = "uksouth", address_prefix = "10.64.0.0/14" }
    ukw = { location = "ukwest", address_prefix = "10.68.0.0/14" }
  }
}

# --- what gets built --------------------------------------------------------

run "two_regions_get_pools_hubs_and_a_hub_mesh" {
  command = apply

  assert {
    condition     = length(azurerm_virtual_network.hub) == 2 && length(azurerm_network_manager_ipam_pool.region) == 2
    error_message = "Expected one hub VNet and one region pool per region."
  }

  assert {
    condition = alltrue([for k, p in azurerm_network_manager_ipam_pool.region :
      p.parent_pool_name == azurerm_network_manager_ipam_pool.root.name &&
      p.location == var.regions[k].location &&
      p.address_prefixes == tolist([var.regions[k].address_prefix])
    ])
    error_message = "Each region pool must be a child of the root pool, in its own region, with its own prefix."
  }

  assert {
    condition = alltrue([for k, v in azurerm_virtual_network.hub :
      v.location == var.regions[k].location &&
      one(v.ip_address_pool).id == azurerm_network_manager_ipam_pool.region[k].id &&
      one(v.ip_address_pool).id != azurerm_network_manager_ipam_pool.root.id &&
      one(v.ip_address_pool).number_of_ip_addresses == "1024"
    ])
    error_message = "Each hub must sit in its region and take 1024 addresses from a region pool — never the root."
  }

  assert {
    condition = length(azurerm_subnet.hub) == 8 && alltrue([for k, s in azurerm_subnet.hub :
      s.virtual_network_name == azurerm_virtual_network.hub[split(".", k)[0]].name &&
      s.resource_group_name == azurerm_resource_group.hub[split(".", k)[0]].name &&
      one(s.ip_address_pool).id == azurerm_network_manager_ipam_pool.region[split(".", k)[0]].id &&
      one(s.ip_address_pool).id != azurerm_network_manager_ipam_pool.root.id
    ])
    error_message = "Expected the four default subnets in each hub, allocated from a region pool."
  }

  assert {
    condition = alltrue([for k, c in azurerm_network_manager_connectivity_configuration.hub_and_spoke :
      c.name == "cc-hubspoke-${k}" &&
      one(c.hub).resource_id == azurerm_virtual_network.hub[k].id &&
      one(c.applies_to_group).network_group_id == azurerm_network_manager_network_group.spokes[k].id &&
      one(c.applies_to_group).network_group_id != azurerm_network_manager_network_group.hubs[0].id &&
      one(c.applies_to_group).group_connectivity == "None"
    ])
    error_message = "Each hub-and-spoke config must apply to a spokes group (not ng-hubs), with no direct spoke-to-spoke links."
  }

  assert {
    condition = (
      length(azurerm_network_manager_connectivity_configuration.hub_mesh) == 1 &&
      length(azurerm_network_manager_static_member.hub) == 2 &&
      alltrue([for m in azurerm_network_manager_static_member.hub : m.network_group_id == azurerm_network_manager_network_group.hubs[0].id]) &&
      one(azurerm_network_manager_connectivity_configuration.hub_mesh[0].applies_to_group).network_group_id == azurerm_network_manager_network_group.hubs[0].id
    )
    error_message = "Both hubs should be static members of ng-hubs, and the mesh should apply to that group."
  }

  assert {
    condition = alltrue([for k, d in azurerm_network_manager_deployment.connectivity :
      d.location == var.regions[k].location &&
      length(d.configuration_ids) == 2 &&
      toset(d.configuration_ids) == toset([
        azurerm_network_manager_connectivity_configuration.hub_and_spoke[k].id,
        azurerm_network_manager_connectivity_configuration.hub_mesh[0].id,
      ])
    ])
    error_message = "Each region must commit a hub-and-spoke config plus the hub mesh — nothing else."
  }

  assert {
    condition     = toset(one(azurerm_network_manager.this.scope).subscription_ids) == toset(["/subscriptions/00000000-0000-0000-0000-000000000000"])
    error_message = "An empty network_manager_scope should default to the current subscription."
  }

  assert {
    condition     = azurerm_virtual_network.hub["uks"].tags["repo"] == "benoitnvl/scandula"
    error_message = "Default tags should be applied."
  }
}

run "one_region_has_no_hub_mesh" {
  command = apply

  variables {
    regions = {
      uks = { location = "uksouth", address_prefix = "10.64.0.0/14" }
    }
  }

  assert {
    condition = (
      length(azurerm_network_manager_connectivity_configuration.hub_mesh) == 0 &&
      length(azurerm_network_manager_network_group.hubs) == 0 &&
      length(azurerm_network_manager_static_member.hub) == 0
    )
    error_message = "A single hub has nothing to mesh with."
  }

  assert {
    condition     = azurerm_network_manager_deployment.connectivity["uks"].configuration_ids == tolist([azurerm_network_manager_connectivity_configuration.hub_and_spoke["uks"].id])
    error_message = "With one region, the deployment should commit only its hub-and-spoke config."
  }
}

run "hub_sizing_and_subnets_are_configurable" {
  command = plan

  variables {
    regions = {
      uks = {
        location       = "uksouth"
        address_prefix = "10.64.0.0/14"
        hub_ip_count   = 256
        hub_subnets    = { GatewaySubnet = 32, AzureFirewallSubnet = 64 }
      }
    }
  }

  assert {
    condition     = one(azurerm_virtual_network.hub["uks"].ip_address_pool).number_of_ip_addresses == "256"
    error_message = "hub_ip_count should drive the hub's allocation."
  }

  assert {
    condition     = length(azurerm_subnet.hub) == 2 && one(azurerm_subnet.hub["uks.GatewaySubnet"].ip_address_pool).number_of_ip_addresses == "32"
    error_message = "hub_subnets should replace the defaults, not add to them."
  }
}

run "management_group_scope_is_passed_through" {
  command = plan

  variables {
    network_manager_scope = {
      management_group_ids = ["/providers/Microsoft.Management/managementGroups/nuvulu"]
    }
  }

  assert {
    condition     = toset(one(azurerm_network_manager.this.scope).management_group_ids) == toset(["/providers/Microsoft.Management/managementGroups/nuvulu"])
    error_message = "An explicit management-group scope should reach the network manager."
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
    regions = { uks = { location = "uksouth", address_prefix = "10.96.0.0/14" } }
  }
  expect_failures = [var.regions]
}

run "rejects_overlapping_regions" {
  command = plan
  variables {
    regions = {
      uks = { location = "uksouth", address_prefix = "10.64.0.0/14" }
      ukw = { location = "ukwest", address_prefix = "10.66.0.0/15" }
    }
  }
  expect_failures = [var.regions]
}

run "rejects_a_non_canonical_region_prefix" {
  command = plan
  variables {
    regions = { uks = { location = "uksouth", address_prefix = "10.65.0.0/14" } }
  }
  expect_failures = [var.regions]
}

run "rejects_a_bad_region_key" {
  command = plan
  variables {
    regions = { UK-South = { location = "uksouth", address_prefix = "10.64.0.0/14" } }
  }
  expect_failures = [var.regions]
}

run "rejects_a_hub_size_that_is_not_a_power_of_two" {
  command = plan
  variables {
    regions = { uks = { location = "uksouth", address_prefix = "10.64.0.0/14", hub_ip_count = 1000 } }
  }
  expect_failures = [var.regions]
}

run "rejects_hub_subnets_that_do_not_fit_the_hub" {
  command = plan
  variables {
    # the four default /26 subnets need 256 addresses
    regions = { uks = { location = "uksouth", address_prefix = "10.64.0.0/14", hub_ip_count = 128 } }
  }
  expect_failures = [var.regions]
}

run "rejects_a_root_that_overlaps_the_homelab" {
  command = plan
  variables {
    ipam_root_prefix = "10.0.0.0/8"
  }
  expect_failures = [var.ipam_root_prefix]
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
    network_manager_scope = { management_group_ids = ["nuvulu"] }
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

run "rejects_a_hub_subnet_that_is_not_a_power_of_two" {
  command = plan
  variables {
    regions = { uks = { location = "uksouth", address_prefix = "10.64.0.0/14", hub_subnets = { GatewaySubnet = 48 } } }
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
