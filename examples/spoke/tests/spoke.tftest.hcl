# Runs against a mocked azurerm: no Azure credentials, nothing real is created,
# so `command = apply` is safe.
#
#   terraform init -backend=false && terraform test
#   (or `make spoke-test` from the repo root)
#
# What this file is really guarding is the one mistake this example exists to
# prevent: writing a CIDR into a spoke. Every run below that touches addresses
# asserts the allocation is asked for and that no literal range is set.
#
# Mock gotchas, as in infra/tests: azurerm validates ID *format* even when mocked,
# so ids handed in as variables are realistic; mock ids are per resource *type*,
# so per-subnet wiring is proven through names and counts, not ids.

mock_provider "azurerm" {
  mock_resource "azurerm_resource_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock" }
  }
  mock_resource "azurerm_virtual_network" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/virtualNetworks/vnet-mock" }
  }
  mock_resource "azurerm_subnet" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/virtualNetworks/vnet-mock/subnets/snet-mock" }
  }
  mock_resource "azurerm_network_security_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/networkSecurityGroups/nsg-mock" }
  }
}

variables {
  name         = "payments"
  location     = "eastasia"
  ipam_pool_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-conn/providers/Microsoft.Network/networkManagers/avnm-scandula/ipamPools/ipam-scandula-eas"

  vnet_address_count = 1024

  subnets = {
    snet-app = {
      address_count = 256
      allow_inbound = {
        from-web-tier = {
          description = "Web tier calls the app API."
          sources     = ["10.64.4.0/24"]
          protocol    = "Tcp"
          ports       = "8443"
        }
      }
    }
    snet-data = { address_count = 256 }
  }
}

# --- the whole point: an allocation, not a CIDR ------------------------------

run "vnet_allocates_from_the_pool_and_hardcodes_nothing" {
  command = apply

  assert {
    # Unset comes back as null under the mock, and as whatever Azure allocated on a
    # real apply — either way, nothing was written down here.
    condition     = try(length(azurerm_virtual_network.this.address_space), 0) == 0
    error_message = "The VNet sets address_space. A spoke must take its range from IPAM, never write one down."
  }

  assert {
    condition     = azurerm_virtual_network.this.ip_address_pool[0].id == var.ipam_pool_id
    error_message = "The VNet allocates from some other pool than the region pool it was given."
  }

  assert {
    condition     = azurerm_virtual_network.this.ip_address_pool[0].number_of_ip_addresses == "1024"
    error_message = "The VNet asked the pool for the wrong number of addresses (the API takes a string)."
  }
}

run "subnets_allocate_from_the_same_pool_and_hardcode_nothing" {
  command = apply

  assert {
    condition     = alltrue([for s in azurerm_subnet.this : try(length(s.address_prefixes), 0) == 0])
    error_message = "A subnet sets address_prefixes. Subnets allocate too — that's the point of doing it this way."
  }

  assert {
    condition     = alltrue([for s in azurerm_subnet.this : s.ip_address_pool[0].id == var.ipam_pool_id])
    error_message = "A subnet allocates from a different pool than the VNet."
  }

  assert {
    condition     = azurerm_subnet.this["snet-app"].ip_address_pool[0].number_of_ip_addresses == "256"
    error_message = "snet-app asked for the wrong number of addresses."
  }

  assert {
    condition     = azurerm_subnet.this["snet-app"].virtual_network_name == azurerm_virtual_network.this.name
    error_message = "The subnets are not in the VNet this root creates."
  }
}

# --- layer 3: the NSG ---------------------------------------------------------

run "nsg_denies_the_rest_of_the_network_under_the_named_rules" {
  command = apply

  assert {
    condition = anytrue([
      for r in azurerm_network_security_group.this["snet-app"].security_rule :
      r.name == "deny-vnet-inbound" && r.access == "Deny" && r.priority == 4000 && r.source_address_prefix == "VirtualNetwork"
    ])
    error_message = "The catch-all deny is missing: Azure's own AllowVnetInBound then permits everything east-west."
  }

  assert {
    condition = anytrue([
      for r in azurerm_network_security_group.this["snet-app"].security_rule :
      r.name == "from-web-tier" && r.access == "Allow" && r.priority < 4000 && r.destination_port_range == "8443"
    ])
    error_message = "The named allow rule is missing, or sits below the catch-all deny where it can never match."
  }

  # A subnet that names nothing gets the deny and nothing else.
  assert {
    condition     = length(azurerm_network_security_group.this["snet-data"].security_rule) == 1
    error_message = "snet-data names no inbound flows, so it should carry the catch-all deny and nothing else."
  }
}

run "every_subnet_is_associated_with_its_nsg" {
  command = apply

  assert {
    condition     = length(azurerm_subnet_network_security_group_association.this) == length(var.subnets)
    error_message = "A subnet has no NSG association — an unattached NSG blocks nothing, and the guardrail policy flags it."
  }

  assert {
    condition = alltrue([
      for k in keys(var.subnets) :
      azurerm_subnet_network_security_group_association.this[k].network_security_group_id == azurerm_network_security_group.this[k].id
    ])
    error_message = "A subnet is associated with another subnet's NSG."
  }
}

run "named_rules_get_distinct_priorities" {
  command = apply

  variables {
    subnets = {
      snet-app = {
        address_count = 256
        allow_inbound = {
          from-web-tier = { description = "d", sources = ["10.64.4.0/24"], protocol = "Tcp", ports = "8443" }
          from-jumpbox  = { description = "d", sources = ["10.64.6.10/32"], protocol = "Tcp", ports = "22" }
          health-probe  = { description = "d", sources = ["AzureLoadBalancer"], protocol = "Tcp", ports = "8443" }
        }
      }
    }
  }

  # Azure rejects an NSG with two rules at the same priority, and the priorities here
  # are derived from map ordering — worth proving rather than assuming.
  assert {
    condition = length(distinct([
      for r in azurerm_network_security_group.this["snet-app"].security_rule : r.priority
    ])) == length(azurerm_network_security_group.this["snet-app"].security_rule)
    error_message = "Two NSG rules share a priority — Azure refuses the whole NSG."
  }

  assert {
    condition = alltrue([
      for r in azurerm_network_security_group.this["snet-app"].security_rule :
      r.priority < 4000 if r.access == "Allow"
    ])
    error_message = "A named allow rule sits at or below the catch-all deny, where it can never match."
  }

  # A service tag has to land in the singular attribute: azurerm's plural one is
  # CIDRs only, and Azure rejects the tag there.
  assert {
    # The `if` filter matters: tolist(null) on the other rules would abort the whole
    # expression rather than yield false.
    condition = anytrue([
      for r in azurerm_network_security_group.this["snet-app"].security_rule :
      r.source_address_prefix == "AzureLoadBalancer" && try(length(r.source_address_prefixes), 0) == 0
      if r.name == "health-probe"
    ])
    error_message = "A service-tag source didn't land in source_address_prefix — Azure refuses a tag in the plural attribute."
  }

  assert {
    condition = anytrue([
      for r in azurerm_network_security_group.this["snet-app"].security_rule :
      length(r.source_address_prefixes) == 1 && contains(r.source_address_prefixes, "10.64.4.0/24") &&
      (r.source_address_prefix == null || r.source_address_prefix == "")
      if r.name == "from-web-tier"
    ])
    error_message = "A CIDR source didn't land in source_address_prefixes."
  }
}

# --- the hub connection, which waits for the hub ------------------------------

run "no_hub_connection_while_the_hub_is_off" {
  command = apply

  assert {
    condition     = length(azurerm_virtual_hub_connection.this) == 0
    error_message = "A hub connection is planned with virtual_hub_id unset. The VNet must build without the (costly) hub."
  }

  assert {
    condition     = output.hub_connection_id == null
    error_message = "hub_connection_id should be null while there is no hub."
  }

  # The allocation is the part that must not wait for the hub.
  assert {
    condition     = length(azurerm_virtual_network.this.ip_address_pool) == 1
    error_message = "The VNet should still take its allocation while the hub is off."
  }
}

run "hub_connection_when_the_hub_exists" {
  command = apply

  variables {
    virtual_hub_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-conn/providers/Microsoft.Network/virtualHubs/vhub-scandula-eas"
  }

  assert {
    condition     = length(azurerm_virtual_hub_connection.this) == 1
    error_message = "No connection to the hub, so the spoke is isolated and nothing routes."
  }

  assert {
    condition     = azurerm_virtual_hub_connection.this[0].remote_virtual_network_id == azurerm_virtual_network.this.id
    error_message = "The connection attaches some other VNet than this spoke's."
  }

  assert {
    condition     = azurerm_virtual_hub_connection.this[0].internet_security_enabled
    error_message = "internet_security_enabled is off, so this spoke's internet traffic bypasses the hub firewall."
  }
}

# --- rejection runs: one per validation in variables.tf ----------------------
# `make mutants` proves each is caught by the validation it's named for. Several
# of these target the same variable, so a green run here is not enough on its own.

run "reject_name_with_uppercase" {
  command = plan
  variables { name = "Payments" }
  expect_failures = [var.name]
}

run "reject_location_display_name" {
  command = plan
  variables { location = "East Asia" }
  expect_failures = [var.location]
}

run "reject_pool_id_that_is_not_a_pool" {
  command = plan
  variables {
    ipam_pool_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-conn/providers/Microsoft.Network/networkManagers/avnm-scandula"
  }
  expect_failures = [var.ipam_pool_id]
}

run "reject_vnet_size_that_is_not_a_power_of_two" {
  command = plan
  variables { vnet_address_count = 1000 }
  expect_failures = [var.vnet_address_count]
}

run "reject_no_subnets" {
  command = plan
  variables { subnets = {} }
  expect_failures = [var.subnets]
}

run "reject_subnet_name_with_a_slash" {
  command = plan
  variables {
    subnets = { "snet/app" = { address_count = 256 } }
  }
  expect_failures = [var.subnets]
}

run "reject_subnet_size_that_is_not_a_power_of_two" {
  command = plan
  variables {
    subnets = { snet-app = { address_count = 300 } }
  }
  expect_failures = [var.subnets]
}

run "reject_subnets_larger_than_the_vnet" {
  command = plan
  variables {
    vnet_address_count = 256
    subnets = {
      snet-app  = { address_count = 256 }
      snet-data = { address_count = 256 }
    }
  }
  expect_failures = [var.subnets]
}

run "reject_any_protocol" {
  command = plan
  variables {
    subnets = {
      snet-app = {
        address_count = 256
        allow_inbound = {
          anything = { description = "d", sources = ["10.64.4.0/24"], protocol = "*", ports = "443" }
        }
      }
    }
  }
  expect_failures = [var.subnets]
}

run "reject_any_port" {
  command = plan
  variables {
    subnets = {
      snet-app = {
        address_count = 256
        allow_inbound = {
          anything = { description = "d", sources = ["10.64.4.0/24"], protocol = "Tcp", ports = "*" }
        }
      }
    }
  }
  expect_failures = [var.subnets]
}

run "reject_port_above_65535" {
  command = plan
  variables {
    subnets = {
      snet-app = {
        address_count = 256
        allow_inbound = {
          anything = { description = "d", sources = ["10.64.4.0/24"], protocol = "Tcp", ports = "99999" }
        }
      }
    }
  }
  expect_failures = [var.subnets]
}

run "reject_inbound_from_the_internet" {
  command = plan
  variables {
    subnets = {
      snet-app = {
        address_count = 256
        allow_inbound = {
          anything = { description = "d", sources = ["Internet"], protocol = "Tcp", ports = "443" }
        }
      }
    }
  }
  expect_failures = [var.subnets]
}

run "reject_service_tag_mixed_with_cidrs" {
  command = plan
  variables {
    subnets = {
      snet-app = {
        address_count = 256
        allow_inbound = {
          anything = { description = "d", sources = ["AzureLoadBalancer", "10.64.4.0/24"], protocol = "Tcp", ports = "443" }
        }
      }
    }
  }
  expect_failures = [var.subnets]
}

run "reject_hub_id_that_is_not_a_hub" {
  command = plan
  variables {
    virtual_hub_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-conn/providers/Microsoft.Network/virtualWans/vwan-scandula"
  }
  expect_failures = [var.virtual_hub_id]
}
