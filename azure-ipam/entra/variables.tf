variable "engine_app_name" {
  description = "Display name of the engine app registration."
  type        = string
  default     = "scandula-ipam-engine"
}

variable "ui_app_name" {
  description = "Display name of the UI app registration (ignored when ui_enabled is false)."
  type        = string
  default     = "scandula-ipam-ui"
}

variable "ui_enabled" {
  description = <<-EOT
    Create the UI app registration. false means API only, like deploy.ps1 -DisableUI:
    no UI app, and no tenant-wide consent to Microsoft Graph Directory.Read.All
    (which only the UI needs).
  EOT
  type        = bool
  default     = true
}

variable "reader_management_group_id" {
  description = <<-EOT
    Where the engine gets Reader, so it can discover VNets: every subscription under
    it. Null (the default) means the tenant root management group, as deploy.ps1
    does. Microsoft's docs discourage anything narrower.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.reader_management_group_id == null || can(regex("^/providers/Microsoft.Management/managementGroups/[^/]+$", var.reader_management_group_id))
    error_message = "reader_management_group_id must be a full id: /providers/Microsoft.Management/managementGroups/<name>."
  }
}

variable "platform_owner_object_ids" {
  description = <<-EOT
    Object ids of the identities that run azure-ipam/platform (part 2), made owners
    of both app registrations. That's what lets part 2 create the engine's client
    secret itself and set the UI's redirect URI, so no secret is ever handed over.
    A user's id: `az ad signed-in-user show --query id -o tsv`. A service principal's:
    `az ad sp show --id <client id> --query id -o tsv`.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.platform_owner_object_ids) > 0 && alltrue([for id in var.platform_owner_object_ids : can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", id))])
    error_message = "platform_owner_object_ids must list at least one object id (a GUID). Without an owner, part 2 can't create the engine secret or set the redirect URI."
  }
}
