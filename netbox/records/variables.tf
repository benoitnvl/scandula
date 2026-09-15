# The address plan as NetBox records it. Nothing here allocates anything in Azure:
# AVNM does that, inside the one block this root marks as delegated to it.

variable "skip_version_check" {
  description = "Skip the provider's NetBox version probe. Only for a plan against an unreachable NetBox — it hides the warning that says the provider and NetBox disagree."
  type        = bool
  default     = false
}

variable "rirs" {
  description = "Registries the aggregates belong to, name => description. RFC 1918 space is its own 'registry' in NetBox's model."
  type        = map(string)
  default = {
    "RFC 1918" = "Private IPv4 space (RFC 1918), Aberdeen's whole internal plan."
  }

  validation {
    condition     = length(var.rirs) > 0
    error_message = "Define at least one RIR: an aggregate can't be filed without one."
  }
}

variable "aggregates" {
  description = <<-EOT
    The top-level blocks Aberdeen is tracking, name => spec. Everything else must sit
    inside one of these.

      prefix       canonical CIDR, e.g. 10.0.0.0/8
      rir          a key of var.rirs
      description  what this block is for
  EOT
  type = map(object({
    prefix      = string
    rir         = string
    description = string
  }))

  validation {
    condition     = length(var.aggregates) > 0
    error_message = "Define at least one aggregate — with none, no prefix below can be filed."
  }

  validation {
    condition     = alltrue([for a in values(var.aggregates) : try(cidrsubnet(a.prefix, 0, 0) == a.prefix, false)])
    error_message = "Every aggregate prefix must be a canonical CIDR with no host bits set, e.g. 10.0.0.0/8."
  }

  validation {
    condition     = alltrue([for a in values(var.aggregates) : contains(keys(var.rirs), a.rir)])
    error_message = "Every aggregate's rir must be a key of var.rirs."
  }
}

variable "avnm_delegated_prefix" {
  description = "The one block delegated to AVNM — the connectivity repo's `ipam_root_prefix`. Recorded as a container so nobody hands out a piece of it from NetBox: inside it, AVNM allocates, and NetBox only records what AVNM was given."
  type        = string

  validation {
    condition     = try(cidrsubnet(var.avnm_delegated_prefix, 0, 0) == var.avnm_delegated_prefix, false)
    error_message = "avnm_delegated_prefix must be a canonical CIDR with no host bits set, e.g. 10.64.0.0/12."
  }

  validation {
    condition = anytrue([for a in values(var.aggregates) : try(
      tonumber(split("/", var.avnm_delegated_prefix)[1]) >= tonumber(split("/", a.prefix)[1]) &&
      cidrsubnet(format("%s/%s", cidrhost(var.avnm_delegated_prefix, 0), split("/", a.prefix)[1]), 0, 0) == cidrsubnet(a.prefix, 0, 0),
    false)])
    error_message = "avnm_delegated_prefix must sit inside one of the aggregates."
  }
}

variable "avnm_region_prefixes" {
  description = "The region pools carved out of the delegated block, name => CIDR (the connectivity repo's `regions[*].address_prefix`). Recorded for visibility; AVNM remains the thing that allocates from them."
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for p in values(var.avnm_region_prefixes) : try(cidrsubnet(p, 0, 0) == p, false)])
    error_message = "Every avnm_region_prefixes value must be a canonical CIDR with no host bits set."
  }

  validation {
    condition = alltrue([for p in values(var.avnm_region_prefixes) : try(
      tonumber(split("/", p)[1]) >= tonumber(split("/", var.avnm_delegated_prefix)[1]) &&
      cidrsubnet(format("%s/%s", cidrhost(p, 0), split("/", var.avnm_delegated_prefix)[1]), 0, 0) == cidrsubnet(var.avnm_delegated_prefix, 0, 0),
    false)])
    error_message = "Every avnm_region_prefixes value must sit inside avnm_delegated_prefix."
  }
}

variable "onprem_prefixes" {
  description = <<-EOT
    On-premises and other non-Azure ranges, name => spec. These are the ranges the
    layer A policy denies in Azure (infra/policy-onprem.tf, `reserved_prefixes`):
    recording them here is what makes that list reviewable instead of folklore.

      prefix       canonical CIDR
      description  what uses it, and where
      status       active (in use), reserved (held), or deprecated (being retired)
  EOT
  type = map(object({
    prefix      = string
    description = string
    status      = optional(string, "active")
  }))
  default = {}

  validation {
    condition     = alltrue([for p in values(var.onprem_prefixes) : try(cidrsubnet(p.prefix, 0, 0) == p.prefix, false)])
    error_message = "Every onprem_prefixes prefix must be a canonical CIDR with no host bits set."
  }

  validation {
    condition     = alltrue([for p in values(var.onprem_prefixes) : contains(["active", "reserved", "deprecated"], p.status)])
    error_message = "Every onprem_prefixes status must be active, reserved or deprecated (NetBox's own values, minus 'container' — these are leaf ranges)."
  }

  # The whole reason NetBox is the authority: it can see both sides. If an
  # on-premises range overlaps the block AVNM hands out, the two will collide the
  # first time a VPN or ExpressRoute gateway joins them.
  validation {
    condition = alltrue([for p in values(var.onprem_prefixes) : try(
      !(
        (tonumber(split("/", p.prefix)[1]) >= tonumber(split("/", var.avnm_delegated_prefix)[1]) &&
        cidrsubnet(format("%s/%s", cidrhost(p.prefix, 0), split("/", var.avnm_delegated_prefix)[1]), 0, 0) == cidrsubnet(var.avnm_delegated_prefix, 0, 0)) ||
        (tonumber(split("/", var.avnm_delegated_prefix)[1]) >= tonumber(split("/", p.prefix)[1]) &&
        cidrsubnet(format("%s/%s", cidrhost(var.avnm_delegated_prefix, 0), split("/", p.prefix)[1]), 0, 0) == cidrsubnet(p.prefix, 0, 0))
      ),
    false)])
    error_message = "An onprem_prefixes range overlaps avnm_delegated_prefix. That collision is exactly what the authority exists to prevent — fix the plan, not this check."
  }
}

variable "default_tags" {
  description = "Tags the provider puts on everything it manages here. They must already exist in NetBox."
  type        = set(string)
  default     = []
}
