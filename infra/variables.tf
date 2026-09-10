# A note on the CIDR checks below. Terraform has no "contains" or "overlaps" for
# prefixes, so they're spelled out with one identity: two CIDRs overlap iff they
# agree on their network bits up to the shorter of the two prefix lengths, and
# `cidrsubnet(x, 0, 0)` returns x with its host bits cleared. Azure would reject a
# bad plan too — but only at apply time, halfway through. These fail at plan (and
# in CI), and every one has a matching run in tests/.

variable "name_prefix" {
  description = "Prefix for every resource name: rg-<prefix>-connectivity, avnm-<prefix>, vnet-<prefix>-hub-<region>, …"
  type        = string
  default     = "scandula"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,14}$", var.name_prefix))
    error_message = "name_prefix must be 2-15 characters of lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "location" {
  description = "Region for the control plane: its resource group, the network manager and the root IPAM pool. Changing it replaces all three."
  type        = string
  default     = "uksouth"
}

variable "tags" {
  description = "Extra tags merged onto everything (managed-by and repo are always set)."
  type        = map(string)
  default     = {}
}

variable "network_manager_scope" {
  description = <<-EOT
    What AVNM may manage. Leave both lists empty to scope it to the subscription
    Terraform runs against. A management-group scope needs Microsoft.Network
    registered at that management group first (docs/bootstrap.md).
  EOT
  type = object({
    management_group_ids = optional(list(string), [])
    subscription_ids     = optional(list(string), [])
  })
  default = {}

  validation {
    condition     = alltrue([for s in var.network_manager_scope.subscription_ids : can(regex("^/subscriptions/[0-9a-fA-F-]{36}$", s))])
    error_message = "subscription_ids must be full ids: /subscriptions/<guid>."
  }

  validation {
    condition     = alltrue([for m in var.network_manager_scope.management_group_ids : can(regex("^/providers/Microsoft.Management/managementGroups/[^/]+$", m))])
    error_message = "management_group_ids must be full ids: /providers/Microsoft.Management/managementGroups/<name>."
  }
}

variable "scope_accesses" {
  description = "Configuration types AVNM may deploy. Connectivity is all this repo uses today; add Routing / SecurityAdmin when a hub gets a firewall."
  type        = list(string)
  default     = ["Connectivity"]

  validation {
    condition     = length(var.scope_accesses) > 0 && alltrue([for a in var.scope_accesses : contains(["Connectivity", "SecurityAdmin", "Routing"], a)])
    error_message = "scope_accesses must be a non-empty subset of Connectivity, SecurityAdmin and Routing."
  }
}

variable "reserved_prefixes" {
  description = "Address space in use outside Azure that the IPAM root must never overlap. Defaults to the homelab LAN, which a site-to-site VPN would route to."
  type        = list(string)
  default     = ["10.1.0.0/23"]

  validation {
    condition     = alltrue([for r in var.reserved_prefixes : can(cidrhost(r, 0))])
    error_message = "reserved_prefixes must all be CIDRs."
  }
}

variable "ipam_root_prefix" {
  description = "The root IPAM pool: all the Azure address space this repo hands out. Region pools are carved from it. Changing it replaces every pool and hub."
  type        = string
  default     = "10.64.0.0/12"

  validation {
    condition     = try(cidrsubnet(var.ipam_root_prefix, 0, 0) == var.ipam_root_prefix, false)
    error_message = "ipam_root_prefix must be a CIDR in canonical form (no host bits set), e.g. 10.64.0.0/12."
  }

  # An unparseable reserved prefix counts as "no overlap" here: reserved_prefixes'
  # own validation rejects it, and one bad input should raise one error, not two.
  validation {
    condition = !anytrue([for r in var.reserved_prefixes : try(
      cidrsubnet(format("%s/%d", cidrhost(r, 0), min(tonumber(split("/", r)[1]), tonumber(split("/", var.ipam_root_prefix)[1]))), 0, 0) ==
      cidrsubnet(format("%s/%d", cidrhost(var.ipam_root_prefix, 0), min(tonumber(split("/", r)[1]), tonumber(split("/", var.ipam_root_prefix)[1]))), 0, 0),
    false)])
    error_message = "ipam_root_prefix overlaps one of reserved_prefixes (the homelab LAN, by default)."
  }
}

variable "regions" {
  description = <<-EOT
    One hub per entry, keyed by a short code that goes into every name (e.g. "uks").
    The key is identity: renaming it, or changing location or address_prefix,
    REPLACES that region's pool, hub, subnets and connectivity configuration.

      location         Azure region of the hub and its pool
      address_prefix   this region's IPAM child pool; must sit inside ipam_root_prefix
      hub_ip_count     addresses the hub VNet takes from the region pool — a power
                       of two; it can grow later but can NEVER shrink
      hub_subnets      subnet name => address count, each allocated from the pool
      use_hub_gateway  spokes route via the hub's VPN/ExpressRoute gateway — set it
                       only once that gateway exists
  EOT
  type = map(object({
    location       = string
    address_prefix = string
    hub_ip_count   = optional(number, 1024)
    hub_subnets = optional(map(number), {
      GatewaySubnet                 = 64
      AzureFirewallSubnet           = 64
      AzureFirewallManagementSubnet = 64
      AzureBastionSubnet            = 64
    })
    use_hub_gateway = optional(bool, false)
  }))

  validation {
    condition     = length(var.regions) > 0 && alltrue([for k in keys(var.regions) : can(regex("^[a-z0-9]{2,6}$", k))])
    error_message = "Define at least one region; keys must be 2-6 lowercase letters or digits (they go into resource names)."
  }

  validation {
    condition     = alltrue([for r in values(var.regions) : try(cidrsubnet(r.address_prefix, 0, 0) == r.address_prefix, false)])
    error_message = "Every region address_prefix must be a CIDR in canonical form (no host bits set), e.g. 10.64.0.0/14."
  }

  validation {
    condition = alltrue([for r in values(var.regions) : try(
      tonumber(split("/", r.address_prefix)[1]) >= tonumber(split("/", var.ipam_root_prefix)[1]) &&
      cidrsubnet(format("%s/%s", cidrhost(r.address_prefix, 0), split("/", var.ipam_root_prefix)[1]), 0, 0) == cidrsubnet(var.ipam_root_prefix, 0, 0),
    false)])
    error_message = "Every region address_prefix must sit inside ipam_root_prefix."
  }

  validation {
    condition = alltrue(flatten([for a, ra in var.regions : [for b, rb in var.regions : a == b || try(
      cidrsubnet(format("%s/%d", cidrhost(ra.address_prefix, 0), min(tonumber(split("/", ra.address_prefix)[1]), tonumber(split("/", rb.address_prefix)[1]))), 0, 0) !=
      cidrsubnet(format("%s/%d", cidrhost(rb.address_prefix, 0), min(tonumber(split("/", ra.address_prefix)[1]), tonumber(split("/", rb.address_prefix)[1]))), 0, 0),
    false)]]))
    error_message = "Region address_prefixes must not overlap each other."
  }

  validation {
    condition     = alltrue([for r in values(var.regions) : contains([for i in range(4, 17) : pow(2, i)], r.hub_ip_count)])
    error_message = "hub_ip_count must be a power of two between 16 and 65536."
  }

  validation {
    condition = alltrue([for r in values(var.regions) :
      alltrue([for n in values(r.hub_subnets) : contains([for i in range(3, 17) : pow(2, i)], n)]) &&
      sum(concat([0], values(r.hub_subnets))) <= r.hub_ip_count
    ])
    error_message = "Each hub subnet size must be a power of two (8 or more), and a hub's subnets must fit inside its hub_ip_count."
  }
}

variable "root_static_cidrs" {
  description = "Blocks inside ipam_root_prefix used outside AVNM's view (a P2S VPN client pool, NVA ranges, …), reserved so IPAM never hands them to a VNet. name => prefixes."
  type        = map(list(string))
  default     = {}

  validation {
    condition = alltrue(flatten([for prefixes in values(var.root_static_cidrs) : [for p in prefixes : try(
      cidrsubnet(p, 0, 0) == p &&
      tonumber(split("/", p)[1]) >= tonumber(split("/", var.ipam_root_prefix)[1]) &&
      cidrsubnet(format("%s/%s", cidrhost(p, 0), split("/", var.ipam_root_prefix)[1]), 0, 0) == cidrsubnet(var.ipam_root_prefix, 0, 0),
    false)]]))
    error_message = "Every root_static_cidrs prefix must be a canonical CIDR inside ipam_root_prefix."
  }
}
