variable "netbox_enabled" {
  description = "Build NetBox. Off by default: this costs roughly $60-100/month (netbox/README.md#cost). With it off the root plans nothing billable, which is what tests/ asserts."
  type        = bool
  default     = false
}

variable "allow_credit_subscription" {
  description = "Allow building on a credit or trial subscription. Don't: NetBox runs continuously, the credit runs out, and Azure then disables the subscription — the tfstate account with it."
  type        = bool
  default     = false
}

variable "name_prefix" {
  description = "Prefix for resource names: rg-<prefix>-netbox, psql-<prefix>-netbox, and so on."
  type        = string
  default     = "scandula"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,14}[a-z0-9]$", var.name_prefix))
    error_message = "name_prefix must be 3-16 lowercase letters, digits or hyphens, starting and ending with a letter or digit."
  }
}

variable "location" {
  description = "Azure region. The control plane region (eastasia) unless there's a reason."
  type        = string
  default     = "eastasia"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{3,30}$", var.location))
    error_message = "location must be a region name like eastasia, not a display name."
  }
}

# --- addressing: NetBox's own VNet comes from AVNM, like any other spoke ------------

variable "ipam_pool_id" {
  description = "The AVNM IPAM pool NetBox's VNet allocates from, from the connectivity repo's `ipam_region_pool_ids` output. NetBox is the authority for the address plan, and it still doesn't get to hand itself a range: it takes an allocation like every other workload."
  type        = string
  default     = null

  validation {
    condition     = var.ipam_pool_id == null || can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.Network/networkManagers/[^/]+/ipamPools/[^/]+$", var.ipam_pool_id))
    error_message = "ipam_pool_id must be a full AVNM IPAM pool resource id (.../networkManagers/<avnm>/ipamPools/<pool>), or null."
  }
}

variable "vnet_address_count" {
  description = "Addresses to allocate for NetBox's VNet. 1024 is a /22 and leaves room: the Container Apps subnet alone needs 512 (a /23) on the Consumption plan."
  type        = number
  default     = 1024

  validation {
    condition     = contains([1024, 2048, 4096, 8192], var.vnet_address_count)
    error_message = "vnet_address_count must be 1024, 2048, 4096 or 8192. Less than 1024 can't hold the Container Apps subnet's required /23 plus the database and private-endpoint subnets."
  }
}

# --- ingress ------------------------------------------------------------------------

variable "public_ingress" {
  description = "Expose NetBox on a public FQDN, restricted to allowed_source_cidrs. There is no VPN or ExpressRoute gateway in the hubs yet (docs/design.md), so an internal-only NetBox is unreachable by people. Set this false once a gateway exists."
  type        = bool
  default     = true
}

variable "allowed_source_cidrs" {
  description = "Source ranges allowed to reach NetBox when public_ingress is on, name => CIDR. Everything else is denied. Aberdeen's office egress IPs and the CI runners, nothing wider."
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for c in values(var.allowed_source_cidrs) : can(cidrhost(c, 0))])
    error_message = "Every allowed_source_cidrs value must be a CIDR, like 203.0.113.10/32."
  }

  validation {
    condition     = !contains(values(var.allowed_source_cidrs), "0.0.0.0/0")
    error_message = "0.0.0.0/0 is not an allow-list. Name the office or runner ranges, or turn public_ingress off."
  }

  validation {
    condition     = alltrue([for name in keys(var.allowed_source_cidrs) : can(regex("^[a-zA-Z0-9][a-zA-Z0-9._-]{0,62}$", name))])
    error_message = "Each allowed_source_cidrs key must be 1-63 characters of letters, digits, '.', '-' or '_' — it becomes the rule name."
  }
}

# --- the database, cache and app ----------------------------------------------------

variable "postgres_sku_name" {
  description = "PostgreSQL Flexible Server compute. B_Standard_B1ms (1 vCore burstable) runs NetBox for a small estate; move to B_Standard_B2s if the UI drags."
  type        = string
  default     = "B_Standard_B1ms"

  validation {
    condition     = can(regex("^(B|GP|MO)_Standard_[A-Za-z0-9_]+$", var.postgres_sku_name))
    error_message = "postgres_sku_name must look like B_Standard_B1ms, GP_Standard_D2s_v3, …"
  }
}

variable "postgres_storage_mb" {
  description = "PostgreSQL storage. 32768 (32 GiB) is the smallest Azure offers and is far more than NetBox needs for an address plan."
  type        = number
  default     = 32768

  validation {
    condition     = contains([32768, 65536, 131072, 262144], var.postgres_storage_mb)
    error_message = "postgres_storage_mb must be one of Azure's sizes: 32768, 65536, 131072 or 262144."
  }
}

variable "postgres_admin_login" {
  description = "Administrator login for PostgreSQL. Its password is generated and kept in Key Vault; nobody types it."
  type        = string
  default     = "netboxadmin"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{2,62}$", var.postgres_admin_login)) && !contains(["azure_superuser", "azure_pg_admin", "admin", "administrator", "root", "guest", "public", "postgres"], var.postgres_admin_login)
    error_message = "postgres_admin_login must be 3-63 lowercase letters, digits or underscores starting with a letter, and not one of Azure's reserved logins (admin, administrator, root, guest, public, postgres, azure_superuser, azure_pg_admin)."
  }
}

variable "backup_retention_days" {
  description = "PostgreSQL backup retention. NetBox is a source of truth: losing it means rebuilding the address plan by hand."
  type        = number
  default     = 14

  validation {
    condition     = var.backup_retention_days >= 7 && var.backup_retention_days <= 35
    error_message = "backup_retention_days must be between 7 and 35. Less than 7 is not a backup policy for a source of truth."
  }
}

variable "web_min_replicas" {
  description = "Minimum web replicas. 1 keeps NetBox warm; 0 saves a few dollars and makes the first request after a quiet spell slow — and the Terraform provider's version probe time out."
  type        = number
  default     = 1

  validation {
    condition     = var.web_min_replicas >= 0 && var.web_min_replicas <= 5
    error_message = "web_min_replicas must be between 0 and 5."
  }
}

variable "log_retention_days" {
  description = "Log Analytics retention for the container and database logs."
  type        = number
  default     = 30

  validation {
    condition     = var.log_retention_days >= 30 && var.log_retention_days <= 730
    error_message = "log_retention_days must be between 30 and 730 (Azure's own range for PerGB2018)."
  }
}

variable "release_file" {
  description = "Override the release pin (release.json). For tests only."
  type        = string
  default     = null
}

variable "tags" {
  description = "Extra tags, merged over the defaults."
  type        = map(string)
  default     = {}
}
