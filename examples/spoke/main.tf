# A spoke VNet whose address space comes from AVNM IPAM, attached to the region's
# secured vWAN hub. Copy this into the repo that owns the spoke; it is never
# applied from scandula.
#
# The point of the example is what *isn't* here: no CIDR, anywhere. The VNet and
# every subnet ask the region pool for a number of addresses and AVNM picks the
# range, so two teams can't pick the same one, and the layer B policy
# (docs/azure-ipam-plan.md) — which denies a VNet holding no allocation from these
# pools — is satisfied by construction.

locals {
  # azurerm's source_address_prefixes takes CIDRs *only* — "Tags may not be used".
  # A service tag (AzureLoadBalancer, VirtualNetwork, a regional tag) has to go in
  # the singular source_address_prefix instead, so each rule is sorted into one or
  # the other here. A validation keeps the two from being mixed in one rule.
  rule_sources = {
    for sname, spec in var.subnets : sname => {
      for rname, r in spec.allow_inbound : rname => {
        service_tag = length(r.sources) == 1 && !can(cidrhost(r.sources[0], 0)) ? r.sources[0] : null
        cidrs       = length(r.sources) == 1 && !can(cidrhost(r.sources[0], 0)) ? null : r.sources
      }
    }
  }
}

resource "azurerm_resource_group" "this" {
  name     = "rg-${var.name}"
  location = var.location
  tags     = var.tags
}

resource "azurerm_virtual_network" "this" {
  name                = "vnet-${var.name}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = var.tags

  # No address_space: the allocation replaces it. Setting both is how a spoke
  # ends up holding a range IPAM never gave it.
  ip_address_pool {
    id = var.ipam_pool_id
    # The API takes a string, not a number.
    number_of_ip_addresses = tostring(var.vnet_address_count)
  }
}

resource "azurerm_subnet" "this" {
  for_each = var.subnets

  name                 = each.key
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name

  # Same pool as the VNet. The prefix lands inside the VNet's own allocation.
  ip_address_pool {
    id                     = var.ipam_pool_id
    number_of_ip_addresses = tostring(each.value.address_count)
  }
}

# One NSG per subnet. Azure's default rules already allow everything inbound from
# VirtualNetwork, which is the hole a flat network is made of, so each NSG names
# what it allows and denies the rest of the network underneath it.
resource "azurerm_network_security_group" "this" {
  for_each = var.subnets

  name                = "nsg-${var.name}-${each.key}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = var.tags

  dynamic "security_rule" {
    for_each = each.value.allow_inbound

    content {
      name                       = security_rule.key
      description                = security_rule.value.description
      priority                   = 100 + index(keys(each.value.allow_inbound), security_rule.key) * 10
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = security_rule.value.protocol
      source_address_prefix      = local.rule_sources[each.key][security_rule.key].service_tag
      source_address_prefixes    = local.rule_sources[each.key][security_rule.key].cidrs
      source_port_range          = "*"
      destination_address_prefix = "*"
      destination_port_range     = security_rule.value.ports
    }
  }

  # Underneath the named rules, and above Azure's AllowVnetInBound default (65000).
  security_rule {
    name                       = "deny-vnet-inbound"
    description                = "Everything east-west that isn't named above. Azure's own AllowVnetInBound would otherwise permit it."
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_address_prefix      = "VirtualNetwork"
    source_port_range          = "*"
    destination_address_prefix = "*"
    destination_port_range     = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "this" {
  for_each = var.subnets

  subnet_id                 = azurerm_subnet.this[each.key].id
  network_security_group_id = azurerm_network_security_group.this[each.key].id
}

# The hub does the routing and the inspection: routing intent in the connectivity
# repo sends this VNet's private *and* internet traffic to the hub firewall, so
# there's no route table here and nothing to allow for egress locally. What the
# firewall then permits is named in scandula's east_west_flows / egress_* — it
# allows nothing by default, so a new spoke reaches nothing until someone adds it.
resource "azurerm_virtual_hub_connection" "this" {
  count = var.virtual_hub_id == null ? 0 : 1

  name                      = "conn-${var.name}"
  virtual_hub_id            = var.virtual_hub_id
  remote_virtual_network_id = azurerm_virtual_network.this.id
  internet_security_enabled = true
}
