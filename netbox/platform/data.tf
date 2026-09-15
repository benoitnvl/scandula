# PostgreSQL, Redis and the media share. All three are reachable only from NetBox's
# own VNet: the database is injected into a delegated subnet, and Redis and the
# storage account have their public endpoints switched off and a private endpoint in
# the private-endpoint subnet.

resource "azurerm_postgresql_flexible_server" "netbox" {
  count = local.enabled ? 1 : 0

  name                = local.names.postgres
  resource_group_name = azurerm_resource_group.netbox[0].name
  location            = var.location
  version             = local.release.postgres_version
  sku_name            = var.postgres_sku_name
  storage_mb          = var.postgres_storage_mb
  tags                = local.tags

  administrator_login    = var.postgres_admin_login
  administrator_password = random_password.postgres[0].result

  # VNet injection: no public endpoint at all, rather than a firewall rule list.
  delegated_subnet_id = azurerm_subnet.postgres[0].id
  private_dns_zone_id = azurerm_private_dns_zone.postgres[0].id

  backup_retention_days        = var.backup_retention_days
  geo_redundant_backup_enabled = false
  auto_grow_enabled            = true

  depends_on = [azurerm_private_dns_zone_virtual_network_link.postgres]

  lifecycle {
    # The zone and the delegated subnet are ForceNew, and replacing the server loses
    # the address plan. Everything else can change in place.
    ignore_changes = [zone]
  }
}

resource "azurerm_postgresql_flexible_server_database" "netbox" {
  count = local.enabled ? 1 : 0

  name      = "netbox"
  server_id = azurerm_postgresql_flexible_server.netbox[0].id
  charset   = "UTF8"
  # NetBox's own documented collation. en_US.utf8 is what its installation guide uses.
  collation = "en_US.utf8"
}

# One cache, two databases: 0 for the task queue (rqworker), 1 for the cache — the
# split netbox-docker makes with two containers.
resource "azurerm_redis_cache" "netbox" {
  count = local.enabled ? 1 : 0

  name                 = local.names.redis
  resource_group_name  = azurerm_resource_group.netbox[0].name
  location             = var.location
  capacity             = 0
  family               = "C"
  sku_name             = "Basic"
  minimum_tls_version  = "1.2"
  non_ssl_port_enabled = false
  tags                 = local.tags

  # Reachable only through the private endpoint below.
  public_network_access_enabled = false
}

resource "azurerm_private_endpoint" "redis" {
  count = local.enabled ? 1 : 0

  name                = "pe-${local.names.redis}"
  resource_group_name = azurerm_resource_group.netbox[0].name
  location            = var.location
  subnet_id           = azurerm_subnet.private[0].id
  tags                = local.tags

  private_service_connection {
    name                           = "redis"
    private_connection_resource_id = azurerm_redis_cache.netbox[0].id
    subresource_names              = ["redisCache"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "redis"
    private_dns_zone_ids = [azurerm_private_dns_zone.redis[0].id]
  }
}

# NetBox's media, reports and scripts directories. Mounted into the web and worker
# containers so both see the same files.
resource "azurerm_storage_account" "netbox" {
  count = local.enabled ? 1 : 0

  name                = local.names.storage
  resource_group_name = azurerm_resource_group.netbox[0].name
  location            = var.location
  tags                = local.tags

  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"

  # Container Apps mounts the share over SMB with the account key, from inside the
  # infrastructure subnet, so the public endpoint stays on but nothing anonymous works.
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = true
}

resource "azurerm_storage_share" "media" {
  count = local.enabled ? 1 : 0

  name               = "netbox-media"
  storage_account_id = azurerm_storage_account.netbox[0].id
  quota              = 50
}
