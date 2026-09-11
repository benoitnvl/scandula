variable "ipam_enabled" {
  description = <<-EOT
    Build Azure IPAM. OFF by default because it runs all the time: a P1v3 App
    Service plan (about $134-158/month) plus Cosmos DB autoscale (about $9-88/month),
    roughly $170-250/month (Azure retail prices, 2026-09-11). Credit subscriptions
    are refused on top of this; see allow_credit_subscription.
  EOT
  type        = bool
  default     = false
}

variable "allow_credit_subscription" {
  description = <<-EOT
    Allow a credit or trial subscription (Visual Studio/MSDN, free trial, Azure Pass,
    sponsorship, students) or any subscription with a spending limit. Refused by
    default: Azure IPAM would use up the credit in about a week, and then Azure
    disables the whole subscription.
  EOT
  type        = bool
  default     = false
}

variable "name_prefix" {
  description = "Goes into every resource name: rg-<prefix>, kv-<prefix>-<suffix>, app-<prefix>-<suffix>, ..."
  type        = string
  default     = "scipam"

  validation {
    # 14 at most keeps kv-<prefix>-<6-char suffix> within Key Vault's 24.
    condition     = can(regex("^[a-z][a-z0-9]{1,13}$", var.name_prefix))
    error_message = "name_prefix must be 2-14 lowercase letters and digits, starting with a letter."
  }
}

variable "location" {
  description = "Region for everything. Southeast Asia is cheaper for P1v3 ($134 vs $158/month)."
  type        = string
  default     = "eastasia"
}

variable "tags" {
  description = "Extra tags merged onto every resource (managed-by, repo and component are always set)."
  type        = map(string)
  default     = {}
}

variable "log_retention_days" {
  description = "Log Analytics retention."
  type        = number
  default     = 30

  validation {
    condition     = var.log_retention_days >= 30 && var.log_retention_days <= 730
    error_message = "log_retention_days must be between 30 and 730."
  }
}

# --- from part 1 (azure-ipam/entra outputs) ----------------------------------------

variable "engine_client_id" {
  description = "Part 1's engine_client_id output."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.engine_client_id))
    error_message = "engine_client_id must be a GUID (part 1's engine_client_id output)."
  }
}

variable "engine_application_id" {
  description = "Part 1's engine_application_id output: /applications/<object id>. The engine secret is created on it."
  type        = string

  validation {
    condition     = can(regex("^/applications/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.engine_application_id))
    error_message = "engine_application_id must be /applications/<object id> (part 1's engine_application_id output)."
  }
}

variable "ui_client_id" {
  description = "Part 1's ui_client_id output. Null for an API-only install (part 1 with ui_enabled = false)."
  type        = string
  default     = null

  validation {
    condition     = var.ui_client_id == null || can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.ui_client_id))
    error_message = "ui_client_id must be a GUID (part 1's ui_client_id output), or null."
  }
}

variable "ui_application_id" {
  description = "Part 1's ui_application_id output: /applications/<object id>. Its redirect URI is set to the web app. Null for an API-only install."
  type        = string
  default     = null

  validation {
    condition     = var.ui_application_id == null || can(regex("^/applications/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.ui_application_id))
    error_message = "ui_application_id must be /applications/<object id> (part 1's ui_application_id output), or null."
  }

  validation {
    condition     = (var.ui_client_id == null) == (var.ui_application_id == null)
    error_message = "Set both ui_client_id and ui_application_id (a UI install) or neither (API only)."
  }
}

# --- the release -------------------------------------------------------------------

variable "zip_path" {
  description = "The release zip. Default: .work/ipam-<version>.zip, where `make ipam-fetch` puts it. Whatever the path, its SHA-256 must match release.json."
  type        = string
  default     = null
}

variable "release_file" {
  description = "The pin. Default: release.json in this directory. Only the tests point it elsewhere."
  type        = string
  default     = null
}
