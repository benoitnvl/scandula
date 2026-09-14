# A note on the CIDR checks below. Terraform has no "contains" or "overlaps" for
# prefixes, so they're spelled out with one identity: two CIDRs overlap iff they
# agree on their network bits up to the shorter of the two prefix lengths, and
# `cidrsubnet(x, 0, 0)` returns x with its host bits cleared. Azure would reject a
# bad plan too — but only at apply time, halfway through. These fail at plan (and
# in CI), and every one has a matching run in tests/.

variable "name_prefix" {
  description = "Prefix for every resource name: rg-<prefix>-connectivity, avnm-<prefix>, vhub-<prefix>-<region>, …"
  type        = string
  default     = "scandula"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,14}$", var.name_prefix))
    error_message = "name_prefix must be 2-15 characters of lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "location" {
  description = "Region for the control plane: its resource groups, the network manager, the root IPAM pool, the Virtual WAN and the firewall policy. Changing it replaces them."
  type        = string
  default     = "eastasia"
}

variable "tags" {
  description = "Extra tags merged onto everything (managed-by and repo are always set)."
  type        = map(string)
  default     = {}
}

variable "secured_vwan_enabled" {
  description = <<-EOT
    Build the Virtual WAN, its hubs, their firewalls and routing intent. OFF by
    default because it is not cheap: each secured hub is a Standard hub
    ($0.25/h) plus a Basic firewall in it ($0.395/h), about $470/month per
    region before data processing (Azure retail prices, 2026-09-10). A Visual
    Studio credit subscription runs out in under two days and is then disabled.
    IPAM pools and the hub address reservations are built either way.
  EOT
  type        = bool
  default     = false
}

variable "firewall_sku_tier" {
  description = "Azure Firewall tier in every hub (and its policy). Basic is the cheapest: up to 250 Mbps, no DNS proxy. Standard costs about 3x."
  type        = string
  default     = "Basic"

  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.firewall_sku_tier)
    error_message = "firewall_sku_tier must be Basic, Standard or Premium."
  }
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
  description = "Configuration types AVNM may deploy. AVNM is only used for IPAM today (hub connectivity is Virtual WAN's job), but the network manager needs at least one."
  type        = list(string)
  default     = ["Connectivity"]

  validation {
    condition     = length(var.scope_accesses) > 0 && alltrue([for a in var.scope_accesses : contains(["Connectivity", "SecurityAdmin", "Routing"], a)])
    error_message = "scope_accesses must be a non-empty subset of Connectivity, SecurityAdmin and Routing."
  }
}

variable "reserved_prefixes" {
  description = "Address space in use outside Azure (on-premises, other clouds) that the IPAM root must never overlap: whatever a site-to-site VPN or ExpressRoute will route to. Empty by default; fill it in before connecting anything on-prem."
  type        = list(string)
  default     = []

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
    error_message = "ipam_root_prefix overlaps one of reserved_prefixes."
  }
}

variable "regions" {
  description = <<-EOT
    One Virtual WAN hub per entry, keyed by a short code that goes into every name
    (e.g. "uks"). The key is identity: renaming it, or changing location or a
    prefix, REPLACES that region's pool and hub.

      location            Azure region of the hub and its pool
      address_prefix      this region's IPAM child pool; must sit inside ipam_root_prefix
      hub_address_prefix  the Virtual WAN hub's own range: /24 or larger (Azure
                          recommends /23), inside address_prefix. A vWAN hub isn't a
                          VNet, so IPAM can't allocate it; it's reserved in the pool
                          as a static CIDR instead, so spokes never get it.
  EOT
  type = map(object({
    location           = string
    address_prefix     = string
    hub_address_prefix = string
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
    condition     = alltrue([for r in values(var.regions) : try(cidrsubnet(r.hub_address_prefix, 0, 0) == r.hub_address_prefix, false)])
    error_message = "Every hub_address_prefix must be a CIDR in canonical form (no host bits set), e.g. 10.64.0.0/23."
  }

  validation {
    condition = alltrue([for r in values(var.regions) : try(
      tonumber(split("/", r.hub_address_prefix)[1]) >= tonumber(split("/", r.address_prefix)[1]) &&
      cidrsubnet(format("%s/%s", cidrhost(r.hub_address_prefix, 0), split("/", r.address_prefix)[1]), 0, 0) == cidrsubnet(r.address_prefix, 0, 0),
    false)])
    error_message = "Every hub_address_prefix must sit inside its own region's address_prefix."
  }

  validation {
    condition     = alltrue([for r in values(var.regions) : try(tonumber(split("/", r.hub_address_prefix)[1]) <= 24, false)])
    error_message = "A Virtual WAN hub needs a /24 or larger (Azure recommends /23)."
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

variable "onprem_policy" {
  description = <<-EOT
    The Azure Policy that stops any VNet under a management group from overlapping
    reserved_prefixes (layer A in docs/azure-ipam-plan.md). OFF until
    management_group_id is set. It reaches every VNet under that management group,
    far beyond this repo, so the owner of policy there decides. The identity running
    Terraform needs Resource Policy Contributor at that management group.

      management_group_id  full id: /providers/Microsoft.Management/managementGroups/<name>.
                           The definition and its assignment both live there.
      effect               Audit (the default) or Deny. Start with Audit and review what it
                           finds. Under Deny, Azure refuses any create or update of an
                           overlapping VNet, including one that already exists.
  EOT
  type = object({
    management_group_id = optional(string)
    effect              = optional(string, "Audit")
  })
  default  = {}
  nullable = false

  validation {
    condition     = var.onprem_policy.management_group_id == null || can(regex("^/providers/Microsoft.Management/managementGroups/[^/]+$", var.onprem_policy.management_group_id))
    error_message = "onprem_policy.management_group_id must be a full id: /providers/Microsoft.Management/managementGroups/<name>."
  }

  validation {
    condition     = contains(["Audit", "Deny"], var.onprem_policy.effect)
    error_message = "onprem_policy.effect must be Audit or Deny."
  }

  # With no ranges the policy would allow every VNet while looking like protection.
  validation {
    condition     = var.onprem_policy.management_group_id == null || length(var.reserved_prefixes) > 0
    error_message = "onprem_policy needs reserved_prefixes: with no on-premises ranges it would allow every VNet."
  }

  # The rule loops over the ranges with a value count, which Azure Policy caps at 100.
  validation {
    condition     = var.onprem_policy.management_group_id == null || length(var.reserved_prefixes) <= 100
    error_message = "onprem_policy can check at most 100 reserved_prefixes (Azure Policy's value count limit): merge them into larger ranges."
  }
}

variable "avnm_allocation_policy" {
  description = <<-EOT
    The Azure Policy that makes every VNet in a migrated scope take its address space
    from this repo's AVNM IPAM region pools (layer B in docs/azure-ipam-plan.md). OFF
    until management_group_id is set.

      management_group_id  full id of the management group the definition lives in. Every
                           assignment scope below must be it or under it: checked at plan
                           against the real hierarchy (policy-avnm.tf).
      assignments          one entry per migrated scope, added as each one migrates.
                           Key: 1-19 lowercase letters, digits or hyphens (the
                           assignment is named avnm-<key>).
        scope        a management group or subscription id. NEVER the landing-zone
                     root while VNets outside AVNM still live under it.
        effect       Audit (default) or Deny. Under Deny, Azure refuses any create or
                     update of a VNet without an allocation, including one that exists.
        not_scopes   exclusions, e.g. a service's managed resource group whose VNets
                     it creates itself.

    The identity running Terraform needs Resource Policy Contributor there.
  EOT
  type = object({
    management_group_id = optional(string)
    assignments = optional(map(object({
      scope      = string
      effect     = optional(string, "Audit")
      not_scopes = optional(list(string), [])
    })), {})
  })
  default  = {}
  nullable = false

  validation {
    condition     = var.avnm_allocation_policy.management_group_id == null || can(regex("^/providers/Microsoft.Management/managementGroups/[^/]+$", var.avnm_allocation_policy.management_group_id))
    error_message = "avnm_allocation_policy.management_group_id must be a full id: /providers/Microsoft.Management/managementGroups/<name>."
  }

  validation {
    condition     = length(var.avnm_allocation_policy.assignments) == 0 || var.avnm_allocation_policy.management_group_id != null
    error_message = "avnm_allocation_policy.assignments need management_group_id: the definition has to live somewhere above them."
  }

  validation {
    condition = alltrue([for a in values(var.avnm_allocation_policy.assignments) :
      can(regex("^/providers/Microsoft.Management/managementGroups/[^/]+$", a.scope)) ||
      can(regex("^/subscriptions/[0-9a-fA-F-]{36}$", a.scope))
    ])
    error_message = "Every avnm_allocation_policy assignment scope must be a management group (/providers/Microsoft.Management/managementGroups/<name>) or a subscription (/subscriptions/<guid>)."
  }

  validation {
    condition     = alltrue([for a in values(var.avnm_allocation_policy.assignments) : contains(["Audit", "Deny"], a.effect)])
    error_message = "Every avnm_allocation_policy assignment effect must be Audit or Deny."
  }

  # avnm-<key>: management-group assignment names are 24 characters at most.
  validation {
    condition     = alltrue([for k in keys(var.avnm_allocation_policy.assignments) : can(regex("^[a-z0-9-]{1,19}$", k))])
    error_message = "avnm_allocation_policy assignment keys must be 1-19 lowercase letters, digits or hyphens."
  }
}

# --- zero trust: what the hub firewall allows (docs/zero-trust.md) -------------------
#
# Nothing is allowed by default. Each flow and each destination is named here, so the
# permission never widens on its own as IPAM hands out new ranges.

variable "east_west_flows" {
  description = <<-EOT
    Traffic allowed between spokes, one entry per approved flow. Empty means spokes
    can't reach each other at all, which is the default.

      sources / destinations  canonical CIDRs inside ipam_root_prefix
      protocols               TCP, UDP or ICMP. "Any" is refused
      ports                   e.g. ["443", "1433", "8000-8100"]. "*" is refused

    Key names the rule (1-40 lowercase letters, digits, hyphens). Put who asked and why
    in the description: it's the audit trail.
  EOT
  type = map(object({
    description  = string
    sources      = list(string)
    destinations = list(string)
    protocols    = list(string)
    ports        = list(string)
  }))
  default  = {}
  nullable = false

  validation {
    condition     = alltrue([for k in keys(var.east_west_flows) : can(regex("^[a-z0-9-]{1,40}$", k))])
    error_message = "east_west_flows keys must be 1-40 lowercase letters, digits or hyphens: they become rule names."
  }

  validation {
    condition     = alltrue([for f in values(var.east_west_flows) : length(f.sources) > 0 && length(f.destinations) > 0 && length(f.protocols) > 0 && length(f.ports) > 0])
    error_message = "Every east_west_flows entry needs at least one source, destination, protocol and port."
  }

  # Inside the root prefix: a flow may only name space this repo hands out.
  validation {
    condition = alltrue(flatten([for f in values(var.east_west_flows) : [for p in concat(f.sources, f.destinations) : try(
      cidrsubnet(p, 0, 0) == p &&
      tonumber(split("/", p)[1]) >= tonumber(split("/", var.ipam_root_prefix)[1]) &&
      cidrsubnet(format("%s/%s", cidrhost(p, 0), split("/", var.ipam_root_prefix)[1]), 0, 0) == cidrsubnet(var.ipam_root_prefix, 0, 0),
    false)]]))
    error_message = "Every east_west_flows source and destination must be a canonical CIDR inside ipam_root_prefix."
  }

  # "Any" and "*" are how a named flow turns back into the blanket rule this replaced.
  validation {
    condition     = alltrue(flatten([for f in values(var.east_west_flows) : [for p in f.protocols : contains(["TCP", "UDP", "ICMP"], p)]]))
    error_message = "east_west_flows protocols must be TCP, UDP or ICMP. \"Any\" is not allowed: name the protocol."
  }

  validation {
    condition     = alltrue(flatten([for f in values(var.east_west_flows) : [for p in f.ports : can(regex("^[0-9]{1,5}(-[0-9]{1,5})?$", p))]]))
    error_message = "east_west_flows ports must be a port or a range, e.g. \"443\" or \"8000-8100\". \"*\" is not allowed: name the ports."
  }

  # The regex above is shape only: "0" and "99999" match it, and azurerm accepts them,
  # so an impossible port would only fail against Azure at apply. (A reversed range like
  # "8100-8000" is the exception: azurerm rejects that itself, at plan.)
  validation {
    condition = alltrue(flatten([for f in values(var.east_west_flows) : [for p in f.ports : try(
      alltrue([for n in split("-", p) : tonumber(n) >= 1 && tonumber(n) <= 65535]) &&
      tonumber(split("-", p)[0]) <= tonumber(element(split("-", p), length(split("-", p)) - 1)),
    false)]]))
    error_message = "east_west_flows ports must be 1-65535, and a range must run low to high, e.g. \"8000-8100\"."
  }
}

variable "egress_https_fqdns" {
  description = "Destinations spokes may reach on HTTPS 443, e.g. [\"login.microsoftonline.com\", \"*.ubuntu.com\"]. Empty means no egress at all."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = alltrue([for f in var.egress_https_fqdns : can(regex("^(\\*\\.)?([a-z0-9-]+\\.)+[a-z]{2,}$", f))])
    error_message = "egress_https_fqdns must be lowercase FQDNs, optionally starting \"*.\". A bare \"*\" is not allowed: that's the wildcard this replaced."
  }
}

variable "egress_http_fqdns" {
  description = "Destinations spokes may reach on plain HTTP 80. Keep this for certificate revocation (CRL, OCSP) only: anything else belongs on 443."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = alltrue([for f in var.egress_http_fqdns : can(regex("^(\\*\\.)?([a-z0-9-]+\\.)+[a-z]{2,}$", f))])
    error_message = "egress_http_fqdns must be lowercase FQDNs, optionally starting \"*.\". A bare \"*\" is not allowed."
  }
}

variable "egress_fqdn_tags" {
  description = "Microsoft FQDN tags spokes may reach, e.g. [\"WindowsUpdate\", \"AzureBackup\"]: Microsoft maintains the addresses behind each."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = alltrue([for t in var.egress_fqdn_tags : can(regex("^[A-Za-z][A-Za-z0-9.-]{1,40}$", t))])
    error_message = "egress_fqdn_tags must be Microsoft FQDN tag names, e.g. WindowsUpdate."
  }
}

variable "firewall_diagnostics_enabled" {
  description = <<-EOT
    Send the hub firewalls' logs and metrics to a Log Analytics workspace. On by
    default, but only builds anything when secured_vwan_enabled is true: without logs
    there's no way to tell what the rules above actually allowed or refused. The
    workspace itself is free; ingestion and retention are not.
  EOT
  type        = bool
  default     = true
  nullable    = false
}

variable "log_retention_days" {
  description = "How long the firewall logs are kept in Log Analytics."
  type        = number
  default     = 30

  validation {
    condition     = var.log_retention_days >= 30 && var.log_retention_days <= 730
    error_message = "log_retention_days must be between 30 and 730."
  }
}
