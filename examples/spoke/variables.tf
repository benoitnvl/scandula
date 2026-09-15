# Sizes are given in *addresses*, not mask bits, because that's what AVNM's API
# takes. 1024 is a /22, 256 a /24, 8 a /29. The accepted sizes are
# every power of two from a /29 (Azure's smallest subnet) to a /8 (its largest
# VNet); anything else is rejected by Azure with a much worse error than this one.

variable "name" {
  description = "The spoke's short name. Resource names are built from it: rg-<name>, vnet-<name>, conn-<name>."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,22}[a-z0-9]$", var.name))
    error_message = "name must be 3-24 lowercase letters, digits or hyphens, starting and ending with a letter or digit."
  }
}

variable "location" {
  description = "Azure region for the spoke. Use the region whose IPAM pool you're allocating from — a VNet can't attach to a hub in another region without extra cost."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{3,30}$", var.location))
    error_message = "location must be a region name like eastasia, not a display name."
  }
}

variable "ipam_pool_id" {
  description = "The region's AVNM IPAM pool, from the connectivity repo's `ipam_region_pool_ids` output. Every prefix here is allocated from it."
  type        = string

  validation {
    condition     = can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.Network/networkManagers/[^/]+/ipamPools/[^/]+$", var.ipam_pool_id))
    error_message = "ipam_pool_id must be a full AVNM IPAM pool resource id (.../networkManagers/<avnm>/ipamPools/<pool>)."
  }
}

variable "vnet_address_count" {
  description = "How many addresses the VNet asks the pool for. AVNM picks the range; nothing here hardcodes a CIDR."
  type        = number

  validation {
    condition = contains(
      [8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536, 131072, 262144, 524288, 1048576, 2097152, 4194304, 8388608, 16777216],
      var.vnet_address_count
    )
    error_message = "vnet_address_count must be a power of two between 8 (a /29) and 16777216 (a /8)."
  }
}

variable "subnets" {
  description = <<-EOT
    Subnets to carve, name => spec. Each one allocates from the same pool.

      address_count   how many addresses this subnet asks for (see the sizes note above)
      allow_inbound   inbound flows to permit, name => spec. Everything else from
                      inside the network is denied: the NSG gets a catch-all
                      deny-from-VirtualNetwork rule underneath these.
                        description  who asked for it, and why
                        sources      source CIDRs, or an Azure service tag
                        protocol     Tcp, Udp or Icmp — never "*"
                        ports        destination ports: "443" or "8000-8080"
  EOT
  type = map(object({
    address_count = number
    allow_inbound = optional(map(object({
      description = string
      sources     = list(string)
      protocol    = string
      ports       = string
    })), {})
  }))

  validation {
    condition     = length(var.subnets) > 0
    error_message = "Define at least one subnet — a VNet with no subnets holds an allocation and serves nothing."
  }

  validation {
    condition     = alltrue([for name in keys(var.subnets) : can(regex("^[a-zA-Z0-9][a-zA-Z0-9._-]{0,78}[a-zA-Z0-9_]$", name))])
    error_message = "Each subnet name must be 2-80 characters of letters, digits, '.', '-' or '_', starting with a letter or digit."
  }

  validation {
    condition = alltrue([
      for s in values(var.subnets) : contains(
        [8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536, 131072, 262144, 524288, 1048576, 2097152, 4194304, 8388608, 16777216],
        s.address_count
      )
    ])
    error_message = "Every subnet address_count must be a power of two between 8 (a /29) and 16777216 (a /8)."
  }

  # Necessary, not sufficient: subnets are carved from the VNet's own allocation,
  # so they can't add up to more than it. They can still fail to fit when the
  # pool aligns them — Azure rejects that at apply, this catches the plain typo.
  validation {
    # The length guard is load-bearing: sum() errors on an empty list, which would
    # crash this check before the "at least one subnet" one above could report.
    condition     = length(var.subnets) == 0 || sum([for s in values(var.subnets) : s.address_count]) <= var.vnet_address_count
    error_message = "The subnets ask for more addresses in total than vnet_address_count."
  }

  validation {
    condition = alltrue(flatten([for s in values(var.subnets) : [
      for r in values(s.allow_inbound) : contains(["Tcp", "Udp", "Icmp"], r.protocol)
    ]]))
    error_message = "Every allow_inbound protocol must be Tcp, Udp or Icmp. \"*\" is not allowed: name the protocol."
  }

  validation {
    condition = alltrue(flatten([for s in values(var.subnets) : [
      for r in values(s.allow_inbound) : can(regex("^[0-9]+(-[0-9]+)?$", r.ports))
    ]]))
    error_message = "Every allow_inbound ports must be a port or a range, like \"443\" or \"8000-8080\". \"*\" is not allowed: name the ports."
  }

  validation {
    # try(..., true): a ports value that isn't numeric at all is the shape check's
    # business. Without this, tonumber("*") aborts the whole plan with its own error
    # and the message above never gets shown.
    condition = alltrue(flatten([for s in values(var.subnets) : [
      for r in values(s.allow_inbound) : try(
        alltrue([for p in split("-", r.ports) : tonumber(p) >= 1 && tonumber(p) <= 65535]) &&
        tonumber(split("-", r.ports)[0]) <= tonumber(element(split("-", r.ports), length(split("-", r.ports)) - 1)),
        true
      )
    ]]))
    error_message = "Every allow_inbound port must be between 1 and 65535, and a range must run low to high."
  }

  validation {
    condition = alltrue(flatten([for s in values(var.subnets) : [
      for r in values(s.allow_inbound) : length(r.sources) > 0 && !contains(r.sources, "*") && !contains(r.sources, "0.0.0.0/0") && !contains(r.sources, "Internet")
    ]]))
    error_message = "Every allow_inbound needs at least one source, and none may be \"*\", 0.0.0.0/0 or the Internet service tag. Inbound from the internet belongs at the hub, not here."
  }

  # azurerm puts CIDRs and service tags in different attributes and refuses to mix
  # them, so a rule is one or the other. Without this the error surfaces at apply,
  # from Azure, about an attribute the tfvars never mentions.
  validation {
    condition = alltrue(flatten([for s in values(var.subnets) : [
      for r in values(s.allow_inbound) :
      alltrue([for src in r.sources : can(cidrhost(src, 0))]) ||
      (length(r.sources) == 1 && can(regex("^[A-Za-z][A-Za-z0-9]{1,49}$", r.sources[0])))
    ]]))
    error_message = "Each allow_inbound sources must be either all CIDRs (10.64.4.0/24, and /32 for a single host) or exactly one Azure service tag. They can't be mixed."
  }
}

variable "virtual_hub_id" {
  description = "The region's secured vWAN hub, from the connectivity repo's `virtual_hubs` output. Leave null while secured_vwan_enabled is off: the VNet and its allocation are built either way, and the connection is added when the hub exists."
  type        = string
  default     = null

  validation {
    # can() swallows the type error when the value is null, so the null case needs no guard of its own.
    condition     = var.virtual_hub_id == null || can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.Network/virtualHubs/[^/]+$", var.virtual_hub_id))
    error_message = "virtual_hub_id must be a full virtual hub resource id (.../providers/Microsoft.Network/virtualHubs/<hub>), or null."
  }
}

variable "tags" {
  description = "Tags for every resource here."
  type        = map(string)
  default     = {}
}
