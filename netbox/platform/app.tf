# The Container Apps environment and the three things that run in it: the web app,
# the rqworker, and the daily housekeeping job.
#
# Consumption plan only (no workload profiles): there's no environment management
# charge on it, and NetBox doesn't need dedicated compute. That's also why the
# infrastructure subnet has to be a /23.

resource "azurerm_container_app_environment" "netbox" {
  count = local.enabled ? 1 : 0

  name                = local.names.environment
  resource_group_name = azurerm_resource_group.netbox[0].name
  location            = var.location
  tags                = local.tags

  infrastructure_subnet_id = azurerm_subnet.apps[0].id
  # Public ingress still terminates on Azure's load balancer; the app's own
  # ip_security_restriction list decides who gets through.
  internal_load_balancer_enabled = !var.public_ingress

  log_analytics_workspace_id = azurerm_log_analytics_workspace.netbox[0].id
  logs_destination           = "log-analytics"
}

# NetBox's media, reports and scripts. Both the web app and the worker mount it.
resource "azurerm_container_app_environment_storage" "media" {
  count = local.enabled ? 1 : 0

  name                         = "netbox-media"
  container_app_environment_id = azurerm_container_app_environment.netbox[0].id
  account_name                 = azurerm_storage_account.netbox[0].name
  share_name                   = azurerm_storage_share.media[0].name
  access_key                   = azurerm_storage_account.netbox[0].primary_access_key
  access_mode                  = "ReadWrite"
}

locals {
  # The environment publishes the domain, so the app's own hostname is known before
  # the app exists — no circular reference through ingress[0].fqdn.
  netbox_fqdn = local.enabled ? "${local.names.web}.${azurerm_container_app_environment.netbox[0].default_domain}" : null

  # What netbox-docker's env/netbox.env sets, pointed at the Azure services. Secret
  # values are not here: they come from Key Vault through the `secret` blocks.
  netbox_env = local.enabled ? {
    ALLOWED_HOSTS = local.netbox_fqdn
    # Container Apps ingress is a reverse proxy, and Django rejects the login POST
    # without this. netbox-docker's own configuration.py says the same.
    CSRF_TRUSTED_ORIGINS = "https://${local.netbox_fqdn}"

    DB_HOST    = azurerm_postgresql_flexible_server.netbox[0].fqdn
    DB_NAME    = azurerm_postgresql_flexible_server_database.netbox[0].name
    DB_USER    = var.postgres_admin_login
    DB_PORT    = "5432"
    DB_SSLMODE = "require" # Azure refuses an unencrypted connection anyway.

    REDIS_HOST = azurerm_redis_cache.netbox[0].hostname
    REDIS_PORT = tostring(local.redis_port)
    REDIS_SSL  = "true"
    # Queue on database 0, cache on database 1 — the split netbox-docker makes with
    # two containers. Everything else about the cache connection is inherited.
    REDIS_DATABASE       = "0"
    REDIS_CACHE_DATABASE = "1"

    MEDIA_ROOT = "/opt/netbox/netbox/media"
    # The superuser and its API token are created once, by hand (netbox/README.md).
    SKIP_SUPERUSER = "true"
    # NetBox phones home for release checks; it has no route out through the firewall
    # and shouldn't need one.
    RELEASE_CHECK_URL = ""
  } : {}

  # Versionless ids: Container Apps then picks up a rotated secret, instead of
  # pinning the version that existed at apply time.
  netbox_secrets = local.enabled ? {
    db-password    = azurerm_key_vault_secret.postgres[0].versionless_id
    redis-password = azurerm_key_vault_secret.redis[0].versionless_id
    django-secret  = azurerm_key_vault_secret.secret_key[0].versionless_id
  } : {}

  # Env entries that read a secret rather than a literal.
  netbox_secret_env = {
    DB_PASSWORD    = "db-password"
    REDIS_PASSWORD = "redis-password"
    SECRET_KEY     = "django-secret"
  }

  worker_command = ["/opt/netbox/venv/bin/python", "/opt/netbox/netbox/manage.py", "rqworker"]
}

resource "azurerm_container_app" "web" {
  count = local.enabled ? 1 : 0

  name                         = local.names.web
  resource_group_name          = azurerm_resource_group.netbox[0].name
  container_app_environment_id = azurerm_container_app_environment.netbox[0].id
  revision_mode                = "Single"
  tags                         = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.netbox[0].id]
  }

  dynamic "secret" {
    for_each = local.netbox_secrets

    content {
      name                = secret.key
      key_vault_secret_id = secret.value
      identity            = azurerm_user_assigned_identity.netbox[0].id
    }
  }

  ingress {
    external_enabled = var.public_ingress
    target_port      = 8080
    transport        = "auto"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }

    # Named sources only. Container Apps denies everything else as soon as one Allow
    # rule exists, so an empty list here with public_ingress on would be wide open —
    # which is what the variable validation refuses.
    dynamic "ip_security_restriction" {
      for_each = var.public_ingress ? var.allowed_source_cidrs : {}

      content {
        name             = ip_security_restriction.key
        ip_address_range = ip_security_restriction.value
        action           = "Allow"
        description      = "Allowed source for the NetBox UI and API."
      }
    }
  }

  template {
    min_replicas = var.web_min_replicas
    max_replicas = 3

    volume {
      name         = "media"
      storage_name = azurerm_container_app_environment_storage.media[0].name
      storage_type = "AzureFile"
    }

    container {
      name   = "netbox"
      image  = local.image
      cpu    = 0.5
      memory = "1Gi"

      dynamic "env" {
        for_each = local.netbox_env

        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = local.netbox_secret_env

        content {
          name        = env.key
          secret_name = env.value
        }
      }

      volume_mounts {
        name = "media"
        path = "/opt/netbox/netbox/media"
      }

      # NetBox's own container health check hits this path; configuration.py always
      # keeps localhost in ALLOWED_HOSTS so the probe isn't rejected.
      # Azure caps initial_delay at 60s, and NetBox's own compose file allows 90s to
      # start. The failure threshold covers the rest: 60s + 10 x 15s before a restart.
      liveness_probe {
        transport               = "HTTP"
        port                    = 8080
        path                    = "/login/"
        initial_delay           = 60
        interval_seconds        = 15
        failure_count_threshold = 10
      }

      readiness_probe {
        transport = "HTTP"
        port      = 8080
        path      = "/login/"
      }
    }
  }

  # Nothing else references the role assignment, so without this the app can be
  # created before the identity may read the vault — and fail to start.
  depends_on = [azurerm_role_assignment.kv_identity]

  lifecycle {
    precondition {
      condition     = !var.public_ingress || length(var.allowed_source_cidrs) > 0
      error_message = "public_ingress is on with an empty allowed_source_cidrs: that publishes NetBox to the internet. Name the office and runner ranges, or set public_ingress = false."
    }
  }
}

# The task queue. No ingress, and it must not scale to zero or queued jobs sit there.
resource "azurerm_container_app" "worker" {
  count = local.enabled ? 1 : 0

  name                         = local.names.worker
  resource_group_name          = azurerm_resource_group.netbox[0].name
  container_app_environment_id = azurerm_container_app_environment.netbox[0].id
  revision_mode                = "Single"
  tags                         = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.netbox[0].id]
  }

  dynamic "secret" {
    for_each = local.netbox_secrets

    content {
      name                = secret.key
      key_vault_secret_id = secret.value
      identity            = azurerm_user_assigned_identity.netbox[0].id
    }
  }

  template {
    min_replicas = 1
    max_replicas = 1

    volume {
      name         = "media"
      storage_name = azurerm_container_app_environment_storage.media[0].name
      storage_type = "AzureFile"
    }

    container {
      name    = "netbox-worker"
      image   = local.image
      cpu     = 0.25
      memory  = "0.5Gi"
      command = local.worker_command

      dynamic "env" {
        for_each = local.netbox_env

        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = local.netbox_secret_env

        content {
          name        = env.key
          secret_name = env.value
        }
      }

      volume_mounts {
        name = "media"
        path = "/opt/netbox/netbox/media"
      }
    }
  }

  # Same ordering as the web app: the vault role must exist first.
  depends_on = [azurerm_role_assignment.kv_identity]
}

# `manage.py housekeeping`, which NetBox expects to run daily: it clears expired
# sessions, old changelog entries and stale job results.
resource "azurerm_container_app_job" "housekeeping" {
  count = local.enabled ? 1 : 0

  name                         = local.names.housekeeping
  resource_group_name          = azurerm_resource_group.netbox[0].name
  location                     = var.location
  container_app_environment_id = azurerm_container_app_environment.netbox[0].id
  replica_timeout_in_seconds   = 1800
  replica_retry_limit          = 1
  tags                         = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.netbox[0].id]
  }

  dynamic "secret" {
    for_each = local.netbox_secrets

    content {
      name                = secret.key
      key_vault_secret_id = secret.value
      identity            = azurerm_user_assigned_identity.netbox[0].id
    }
  }

  schedule_trigger_config {
    cron_expression = "0 1 * * *"
  }

  template {
    container {
      name    = "housekeeping"
      image   = local.image
      cpu     = 0.25
      memory  = "0.5Gi"
      command = ["/opt/netbox/venv/bin/python", "/opt/netbox/netbox/manage.py", "housekeeping"]

      dynamic "env" {
        for_each = local.netbox_env

        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = local.netbox_secret_env

        content {
          name        = env.key
          secret_name = env.value
        }
      }
    }
  }

  # Same ordering as the web app: the vault role must exist first.
  depends_on = [azurerm_role_assignment.kv_identity]
}
