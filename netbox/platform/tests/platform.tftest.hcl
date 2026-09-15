# NetBox's Azure platform against a mocked azurerm/random/time: no Azure, no
# credentials, nothing created.
#
#   make netbox-test
#
# What this can't prove: that Azure accepts these resources, or that NetBox starts.
# What it does prove: the cost guard, that the image is pinned by digest, that
# nothing is reachable from the internet unless it was named, that the containers
# get the settings NetBox actually reads, and the wiring between them.

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "11111111-1111-1111-1111-111111111111"
      object_id       = "0e0e0e0e-0000-0000-0000-000000000001"
      client_id       = "0c0c0c0c-0000-0000-0000-000000000001"
      subscription_id = "00000000-0000-0000-0000-000000000000"
    }
  }
  mock_data "azurerm_subscription" {
    defaults = {
      id              = "/subscriptions/00000000-0000-0000-0000-000000000000"
      subscription_id = "00000000-0000-0000-0000-000000000000"
      quota_id        = "EnterpriseAgreement_2014-09-01"
      spending_limit  = "Off"
    }
  }

  mock_resource "azurerm_resource_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-scandula-netbox" }
  }
  mock_resource "azurerm_user_assigned_identity" {
    defaults = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-scandula-netbox/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-scandula-netbox"
      principal_id = "1d1d1d1d-0000-0000-0000-000000000001"
      client_id    = "1c1c1c1c-0000-0000-0000-000000000001"
    }
  }
  mock_resource "azurerm_virtual_network" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-scandula-netbox/providers/Microsoft.Network/virtualNetworks/vnet-scandula-netbox" }
  }
  mock_resource "azurerm_subnet" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-scandula-netbox/providers/Microsoft.Network/virtualNetworks/vnet-scandula-netbox/subnets/snet-mock" }
  }
  mock_resource "azurerm_private_dns_zone" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-scandula-netbox/providers/Microsoft.Network/privateDnsZones/zone-mock" }
  }
  mock_resource "azurerm_log_analytics_workspace" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-scandula-netbox/providers/Microsoft.OperationalInsights/workspaces/log-scandula-netbox" }
  }
  mock_resource "azurerm_key_vault" {
    defaults = {
      id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-scandula-netbox/providers/Microsoft.KeyVault/vaults/kv-scandula-nb-abc123"
      vault_uri = "https://kv-scandula-nb-abc123.vault.azure.net/"
    }
  }
  mock_resource "azurerm_key_vault_secret" {
    defaults = {
      id             = "https://kv-scandula-nb-abc123.vault.azure.net/secrets/mock/0123456789abcdef0123456789abcdef"
      versionless_id = "https://kv-scandula-nb-abc123.vault.azure.net/secrets/mock"
    }
  }
  mock_resource "azurerm_postgresql_flexible_server" {
    defaults = {
      id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-scandula-netbox/providers/Microsoft.DBforPostgreSQL/flexibleServers/psql-scandula-netbox-abc123"
      fqdn = "psql-scandula-netbox-abc123.postgres.database.azure.com"
    }
  }
  mock_resource "azurerm_redis_cache" {
    defaults = {
      id                 = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-scandula-netbox/providers/Microsoft.Cache/redis/redis-scandula-netbox-abc123"
      hostname           = "redis-scandula-netbox-abc123.redis.cache.windows.net"
      primary_access_key = "mock-redis-key"
    }
  }
  mock_resource "azurerm_storage_account" {
    defaults = {
      id                 = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-scandula-netbox/providers/Microsoft.Storage/storageAccounts/stscandulanbabc123"
      primary_access_key = "mock-storage-key"
    }
  }
  mock_resource "azurerm_container_app_environment" {
    defaults = {
      id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-scandula-netbox/providers/Microsoft.App/managedEnvironments/cae-scandula-netbox"
      default_domain = "mockregion.azurecontainerapps.io"
    }
  }
}

variables {
  ipam_pool_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-conn/providers/Microsoft.Network/networkManagers/avnm-scandula/ipamPools/ipam-scandula-eas"
  allowed_source_cidrs = {
    office = "203.0.113.0/24"
  }
}

# --- the cost guard -----------------------------------------------------------------

run "netbox_is_off_by_default" {
  command = apply

  assert {
    condition = (
      length(azurerm_resource_group.netbox) == 0 &&
      length(azurerm_postgresql_flexible_server.netbox) == 0 &&
      length(azurerm_redis_cache.netbox) == 0 &&
      length(azurerm_container_app_environment.netbox) == 0 &&
      length(azurerm_container_app.web) == 0 &&
      length(azurerm_container_app.worker) == 0 &&
      length(azurerm_container_app_job.housekeeping) == 0 &&
      length(azurerm_storage_account.netbox) == 0 &&
      length(azurerm_log_analytics_workspace.netbox) == 0
    )
    error_message = "Something billable is planned with netbox_enabled = false. This runs continuously; off must mean nothing."
  }

  assert {
    condition     = output.netbox_url == null
    error_message = "netbox_url should be null while NetBox isn't built."
  }
}

run "off_needs_no_pool" {
  command = apply

  variables {
    ipam_pool_id = null
  }

  assert {
    condition     = length(azurerm_virtual_network.netbox) == 0
    error_message = "With NetBox off, the root must plan nothing at all — not even a VNet."
  }
}

# --- the pin --------------------------------------------------------------------------

run "image_is_pinned_by_digest" {
  command = apply

  variables {
    netbox_enabled = true
  }

  assert {
    condition = alltrue([
      for image in [
        azurerm_container_app.web[0].template[0].container[0].image,
        azurerm_container_app.worker[0].template[0].container[0].image,
        azurerm_container_app_job.housekeeping[0].template[0].container[0].image,
      ] : image == "docker.io/netboxcommunity/netbox@sha256:691ec1a4f569f3dfb9fefd9f086cca1b39689ad59c3eae753712a741447e5e60"
    ])
    error_message = "The three containers must all run the digest pinned in release.json. A tag moves; that's the whole point of the pin."
  }

  # A tag would still deploy; it just would not be a pin.
  assert {
    condition     = !strcontains(azurerm_container_app.web[0].template[0].container[0].image, ":v")
    error_message = "The image is referenced by tag, not by digest."
  }
}

# --- addressing: NetBox takes an allocation like everyone else -------------------------

run "netbox_allocates_its_own_vnet_from_avnm" {
  command = apply

  variables {
    netbox_enabled = true
  }

  assert {
    condition     = try(length(azurerm_virtual_network.netbox[0].address_space), 0) == 0
    error_message = "NetBox's VNet sets address_space. It's the authority for the address plan and it still doesn't get to write its own range down."
  }

  assert {
    condition     = azurerm_virtual_network.netbox[0].ip_address_pool[0].id == var.ipam_pool_id
    error_message = "NetBox's VNet doesn't allocate from the AVNM pool it was given."
  }

  assert {
    condition = alltrue([
      azurerm_subnet.apps[0].ip_address_pool[0].number_of_ip_addresses == "512",
      azurerm_subnet.postgres[0].ip_address_pool[0].number_of_ip_addresses == "16",
      azurerm_subnet.private[0].ip_address_pool[0].number_of_ip_addresses == "16",
    ])
    error_message = "The subnets ask for the wrong sizes — Container Apps Consumption needs a /23 (512) for its infrastructure subnet."
  }

  assert {
    condition     = azurerm_subnet.apps[0].delegation[0].service_delegation[0].name == "Microsoft.App/environments"
    error_message = "The Container Apps subnet isn't delegated to Microsoft.App/environments."
  }

  assert {
    condition     = azurerm_subnet.postgres[0].delegation[0].service_delegation[0].name == "Microsoft.DBforPostgreSQL/flexibleServers"
    error_message = "The database subnet isn't delegated to PostgreSQL, so VNet injection can't work."
  }
}

# --- nothing is reachable that wasn't named ---------------------------------------------

run "data_services_are_private" {
  command = apply

  variables {
    netbox_enabled = true
  }

  assert {
    condition     = azurerm_redis_cache.netbox[0].public_network_access_enabled == false
    error_message = "Redis has a public endpoint. It holds NetBox's session and task data."
  }

  assert {
    condition     = azurerm_redis_cache.netbox[0].non_ssl_port_enabled == false
    error_message = "Redis accepts unencrypted connections."
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.netbox[0].delegated_subnet_id == azurerm_subnet.postgres[0].id
    error_message = "PostgreSQL isn't injected into the delegated subnet, which means it has a public endpoint instead."
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.netbox[0].private_dns_zone_id == azurerm_private_dns_zone.postgres[0].id
    error_message = "PostgreSQL isn't published into the private zone, so the containers can't resolve it."
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.netbox[0].backup_retention_days >= 7
    error_message = "Backups shorter than a week, for the source of truth of the address plan."
  }
}

run "ingress_allows_only_named_sources" {
  command = apply

  variables {
    netbox_enabled = true
    allowed_source_cidrs = {
      office  = "203.0.113.0/24"
      runners = "198.51.100.7/32"
    }
  }

  assert {
    condition     = length(azurerm_container_app.web[0].ingress[0].ip_security_restriction) == 2
    error_message = "The allow-list didn't reach the ingress. Container Apps denies everything else only once an Allow rule exists."
  }

  assert {
    condition = alltrue([
      for r in azurerm_container_app.web[0].ingress[0].ip_security_restriction : r.action == "Allow"
    ])
    error_message = "A restriction is not an Allow rule; mixing actions changes how Container Apps evaluates the list."
  }

  assert {
    condition     = azurerm_container_app.web[0].ingress[0].target_port == 8080
    error_message = "Ingress doesn't point at 8080, which is the port the NetBox container listens on."
  }
}

run "internal_ingress_has_no_allow_list" {
  command = apply

  variables {
    netbox_enabled       = true
    public_ingress       = false
    allowed_source_cidrs = {}
  }

  assert {
    condition     = azurerm_container_app.web[0].ingress[0].external_enabled == false
    error_message = "public_ingress is off but ingress is still external."
  }

  assert {
    condition     = azurerm_container_app_environment.netbox[0].internal_load_balancer_enabled
    error_message = "The environment still has a public load balancer with public_ingress off."
  }

  assert {
    condition     = length(azurerm_container_app.web[0].ingress[0].ip_security_restriction) == 0
    error_message = "An internal-only app doesn't need a source allow-list, and having one there is misleading."
  }
}

run "reject_public_ingress_with_no_allow_list" {
  command = plan

  variables {
    netbox_enabled       = true
    public_ingress       = true
    allowed_source_cidrs = {}
  }

  expect_failures = [azurerm_container_app.web]
}

run "reject_enabled_without_a_pool" {
  command = plan

  variables {
    netbox_enabled = true
    ipam_pool_id   = null
  }

  expect_failures = [azurerm_virtual_network.netbox]
}

run "reject_credit_subscription" {
  command = plan

  variables {
    netbox_enabled = true
  }

  override_data {
    target = data.azurerm_subscription.current[0]
    values = {
      id              = "/subscriptions/00000000-0000-0000-0000-000000000000"
      subscription_id = "00000000-0000-0000-0000-000000000000"
      quota_id        = "MSDN_2014-09-01"
      spending_limit  = "On"
    }
  }

  expect_failures = [azurerm_resource_group.netbox]
}

# --- what the containers actually read ---------------------------------------------------

run "containers_get_the_settings_netbox_reads" {
  command = apply

  variables {
    netbox_enabled = true
  }

  assert {
    condition = anytrue([
      for e in azurerm_container_app.web[0].template[0].container[0].env :
      e.value == "require" if e.name == "DB_SSLMODE"
    ])
    error_message = "DB_SSLMODE isn't 'require'. NetBox's default is 'prefer', which would silently accept an unencrypted connection."
  }

  assert {
    condition = anytrue([
      for e in azurerm_container_app.web[0].template[0].container[0].env :
      e.value == "true" if e.name == "REDIS_SSL"
    ])
    error_message = "REDIS_SSL isn't on, so NetBox would talk to Redis in the clear."
  }

  assert {
    condition = anytrue([
      for e in azurerm_container_app.web[0].template[0].container[0].env :
      e.value == "6380" if e.name == "REDIS_PORT"
    ])
    error_message = "REDIS_PORT isn't 6380, which is the only port an SSL-only Azure cache answers on."
  }

  assert {
    condition = anytrue([
      for e in azurerm_container_app.web[0].template[0].container[0].env :
      endswith(e.value, ".mockregion.azurecontainerapps.io") if e.name == "ALLOWED_HOSTS"
    ])
    error_message = "ALLOWED_HOSTS isn't the app's own hostname — Django rejects every request, or accepts any Host header."
  }

  # Container Apps ingress is a reverse proxy; without this the login POST fails
  # with a CSRF error and nothing in the Azure portal explains why.
  assert {
    condition = anytrue([
      for e in azurerm_container_app.web[0].template[0].container[0].env :
      startswith(e.value, "https://") && endswith(e.value, ".mockregion.azurecontainerapps.io")
      if e.name == "CSRF_TRUSTED_ORIGINS"
    ])
    error_message = "CSRF_TRUSTED_ORIGINS isn't the app's own https origin, so nobody can log in."
  }

  # A versioned id would pin the secret as it was at apply time.
  assert {
    condition = alltrue([
      for sec in azurerm_container_app.web[0].secret :
      !can(regex("/secrets/[^/]+/[0-9a-f]{32}$", sec.key_vault_secret_id))
    ])
    error_message = "A secret is referenced by version, so rotating it in Key Vault would not reach the container."
  }

  # The queue and the cache must not share a database, or rqworker and the cache
  # evict each other's keys.
  assert {
    condition = anytrue([
      for e in azurerm_container_app.web[0].template[0].container[0].env :
      e.value == "0" if e.name == "REDIS_DATABASE"
      ]) && anytrue([
      for e in azurerm_container_app.web[0].template[0].container[0].env :
      e.value == "1" if e.name == "REDIS_CACHE_DATABASE"
    ])
    error_message = "The task queue and the cache aren't on separate Redis databases."
  }

  assert {
    condition = alltrue([
      for name in ["DB_PASSWORD", "REDIS_PASSWORD", "SECRET_KEY"] : anytrue([
        for e in azurerm_container_app.web[0].template[0].container[0].env :
        e.secret_name != null && e.secret_name != "" if e.name == name
      ])
    ])
    error_message = "A credential is passed as a literal env value instead of a secret reference."
  }

  assert {
    condition = alltrue([
      for s in azurerm_container_app.web[0].secret : s.key_vault_secret_id != null && s.key_vault_secret_id != ""
    ])
    error_message = "A container secret holds a literal value instead of reading from Key Vault."
  }
}

run "worker_and_housekeeping_run_the_right_commands" {
  command = apply

  variables {
    netbox_enabled = true
  }

  assert {
    condition     = contains(azurerm_container_app.worker[0].template[0].container[0].command, "rqworker")
    error_message = "The worker isn't running rqworker, so background jobs never execute."
  }

  assert {
    condition     = azurerm_container_app.worker[0].template[0].min_replicas == 1
    error_message = "The worker can scale to zero, which leaves queued jobs sitting there."
  }

  assert {
    condition     = length(azurerm_container_app.worker[0].ingress) == 0
    error_message = "The worker has ingress. Nothing should be able to reach it."
  }

  assert {
    condition     = contains(azurerm_container_app_job.housekeeping[0].template[0].container[0].command, "housekeeping")
    error_message = "The daily job isn't running manage.py housekeeping."
  }

  assert {
    condition     = azurerm_container_app_job.housekeeping[0].schedule_trigger_config[0].cron_expression == "0 1 * * *"
    error_message = "The housekeeping job isn't on a daily schedule."
  }

  # Both mount the same share, or a report written by the worker isn't visible in the UI.
  assert {
    condition = (
      azurerm_container_app.web[0].template[0].volume[0].storage_name ==
      azurerm_container_app.worker[0].template[0].volume[0].storage_name
    )
    error_message = "The web app and the worker mount different shares."
  }
}

# --- rejection runs: one per validation in variables.tf ---------------------------------

run "reject_bad_name_prefix" {
  command = plan
  variables { name_prefix = "Scandula" }
  expect_failures = [var.name_prefix]
}

run "reject_location_display_name" {
  command = plan
  variables { location = "East Asia" }
  expect_failures = [var.location]
}

run "reject_pool_id_that_is_not_a_pool" {
  command = plan
  variables { ipam_pool_id = "/subscriptions/x/resourceGroups/y/providers/Microsoft.Network/networkManagers/avnm" }
  expect_failures = [var.ipam_pool_id]
}

run "reject_vnet_too_small_for_container_apps" {
  command = plan
  variables { vnet_address_count = 512 }
  expect_failures = [var.vnet_address_count]
}

run "reject_allow_list_entry_that_is_not_a_cidr" {
  command = plan
  variables { allowed_source_cidrs = { office = "203.0.113.10" } }
  expect_failures = [var.allowed_source_cidrs]
}

run "reject_allow_all_in_the_allow_list" {
  command = plan
  variables { allowed_source_cidrs = { everyone = "0.0.0.0/0" } }
  expect_failures = [var.allowed_source_cidrs]
}

run "reject_allow_list_key_that_is_not_a_rule_name" {
  command = plan
  variables { allowed_source_cidrs = { "office network!" = "203.0.113.0/24" } }
  expect_failures = [var.allowed_source_cidrs]
}

run "reject_bad_postgres_sku" {
  command = plan
  variables { postgres_sku_name = "B1ms" }
  expect_failures = [var.postgres_sku_name]
}

run "reject_postgres_storage_azure_does_not_sell" {
  command = plan
  variables { postgres_storage_mb = 10240 }
  expect_failures = [var.postgres_storage_mb]
}

run "reject_reserved_postgres_login" {
  command = plan
  variables { postgres_admin_login = "postgres" }
  expect_failures = [var.postgres_admin_login]
}

run "reject_backup_retention_under_a_week" {
  command = plan
  variables { backup_retention_days = 3 }
  expect_failures = [var.backup_retention_days]
}

run "reject_too_many_web_replicas" {
  command = plan
  variables { web_min_replicas = 9 }
  expect_failures = [var.web_min_replicas]
}

run "reject_log_retention_below_azure_minimum" {
  command = plan
  variables { log_retention_days = 7 }
  expect_failures = [var.log_retention_days]
}
