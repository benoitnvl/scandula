# NetBox's own VNet, allocated from AVNM like any other workload — see examples/spoke
# for the same pattern. Nothing here writes a CIDR down.
#
# Three subnets: the Container Apps infrastructure subnet (a /23 is the Consumption
# plan's minimum), the delegated subnet PostgreSQL Flexible Server is injected into,
# and one for private endpoints (Redis, storage).
#
# ⚠ No NSGs yet. The Container Apps infrastructure subnet has its own required flows
# and a wrong rule there breaks the environment in ways that are hard to read. It's
# recorded as a gap in netbox/README.md rather than guessed at here.

resource "azurerm_virtual_network" "netbox" {
  count = local.enabled ? 1 : 0

  name                = local.names.vnet
  resource_group_name = azurerm_resource_group.netbox[0].name
  location            = var.location
  tags                = local.tags

  ip_address_pool {
    id                     = var.ipam_pool_id
    number_of_ip_addresses = tostring(var.vnet_address_count)
  }

  lifecycle {
    precondition {
      condition     = var.ipam_pool_id != null
      error_message = "ipam_pool_id is required with netbox_enabled = true: NetBox's VNet allocates from AVNM. Take it from the connectivity repo's ipam_region_pool_ids output."
    }
  }
}

resource "azurerm_subnet" "apps" {
  count = local.enabled ? 1 : 0

  name                 = "snet-apps"
  resource_group_name  = azurerm_resource_group.netbox[0].name
  virtual_network_name = azurerm_virtual_network.netbox[0].name

  ip_address_pool {
    id                     = var.ipam_pool_id
    number_of_ip_addresses = tostring(local.subnet_sizes.apps)
  }

  delegation {
    name = "container-apps"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "postgres" {
  count = local.enabled ? 1 : 0

  name                 = "snet-postgres"
  resource_group_name  = azurerm_resource_group.netbox[0].name
  virtual_network_name = azurerm_virtual_network.netbox[0].name

  ip_address_pool {
    id                     = var.ipam_pool_id
    number_of_ip_addresses = tostring(local.subnet_sizes.postgres)
  }

  delegation {
    name = "postgres"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "private" {
  count = local.enabled ? 1 : 0

  name                 = "snet-private-endpoints"
  resource_group_name  = azurerm_resource_group.netbox[0].name
  virtual_network_name = azurerm_virtual_network.netbox[0].name

  ip_address_pool {
    id                     = var.ipam_pool_id
    number_of_ip_addresses = tostring(local.subnet_sizes.private)
  }
}

# --- private DNS -------------------------------------------------------------------

# A VNet-injected Flexible Server needs a zone whose name ends in
# .private.postgres.database.azure.com, and the server's FQDN is published into it.
resource "azurerm_private_dns_zone" "postgres" {
  count = local.enabled ? 1 : 0

  name                = local.names.postgres_dns
  resource_group_name = azurerm_resource_group.netbox[0].name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  count = local.enabled ? 1 : 0

  name                 = "netbox"
  private_dns_zone_id  = azurerm_private_dns_zone.postgres[0].id
  virtual_network_id   = azurerm_virtual_network.netbox[0].id
  registration_enabled = false
  tags                 = local.tags
}

resource "azurerm_private_dns_zone" "redis" {
  count = local.enabled ? 1 : 0

  name                = "privatelink.redis.cache.windows.net"
  resource_group_name = azurerm_resource_group.netbox[0].name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "redis" {
  count = local.enabled ? 1 : 0

  name                 = "netbox"
  private_dns_zone_id  = azurerm_private_dns_zone.redis[0].id
  virtual_network_id   = azurerm_virtual_network.netbox[0].id
  registration_enabled = false
  tags                 = local.tags
}
