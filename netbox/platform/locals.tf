locals {
  # The pin: NetBox version and the image digest it resolved to, plus the provider
  # version that digest was chosen for. Change them together, in a PR.
  release = jsondecode(file(coalesce(var.release_file, "${path.module}/release.json")))

  # Digest, not tag. A tag moves; the whole point of pinning is that it can't.
  image = "${local.release.image}@${local.release.image_digest}"

  enabled = var.netbox_enabled

  # Global names need a suffix; it's made once and kept in state.
  suffix = try(random_string.suffix[0].result, "")
  names = {
    resource_group = "rg-${var.name_prefix}-netbox"
    identity       = "id-${var.name_prefix}-netbox"
    log_analytics  = "log-${var.name_prefix}-netbox"
    vnet           = "vnet-${var.name_prefix}-netbox"
    environment    = "cae-${var.name_prefix}-netbox"
    web            = "ca-${var.name_prefix}-netbox"
    worker         = "ca-${var.name_prefix}-netbox-worker"
    housekeeping   = "caj-${var.name_prefix}-netbox-housekeeping"
    postgres       = "psql-${var.name_prefix}-netbox-${local.suffix}"
    redis          = "redis-${var.name_prefix}-netbox-${local.suffix}"
    key_vault      = "kv-${var.name_prefix}-nb-${local.suffix}"
    storage        = "st${replace(var.name_prefix, "-", "")}nb${local.suffix}"
    postgres_dns   = "${var.name_prefix}-netbox.private.postgres.database.azure.com"
  }

  tags = merge({
    managed-by = "terraform"
    repo       = "benoitnvl/scandula"
    component  = "netbox"
  }, var.tags)

  # Subscription offer ids (quotaId) of credit and trial subscriptions.
  credit_offer_pattern = "^(MSDN|FreeTrial|AzurePass|Sponsored|DreamSpark|Students|AzureForStudents)"

  # Subnet sizes. The Container Apps Consumption plan requires a /23 (512) for its
  # infrastructure subnet; the other two only need a /28 (16) each.
  subnet_sizes = {
    apps     = 512
    postgres = 16
    private  = 16
  }

  # Azure Cache for Redis speaks TLS on 6380. NetBox's container takes host, port,
  # password and an SSL flag for two separate Redis uses: the task queue (database 0)
  # and the cache (database 1).
  redis_port = 6380
}
