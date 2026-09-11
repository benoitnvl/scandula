locals {
  # The pin: release, commit and the SHA-256 of its ipam.zip, plus the Python the
  # engine targets (engine/app/version.json). Change them together, in a PR.
  release  = jsondecode(file(coalesce(var.release_file, "${path.module}/release.json")))
  zip_path = coalesce(var.zip_path, "${path.module}/.work/ipam-${local.release.version}.zip")

  ui_enabled = var.ui_client_id != null

  # Global names need a suffix; it's made once and kept in state.
  suffix = try(random_string.suffix[0].result, "")
  names = {
    resource_group = "rg-${var.name_prefix}"
    identity       = "id-${var.name_prefix}"
    log_analytics  = "log-${var.name_prefix}"
    service_plan   = "asp-${var.name_prefix}"
    key_vault      = "kv-${var.name_prefix}-${local.suffix}"
    cosmos         = "cosmos-${var.name_prefix}-${local.suffix}"
    web_app        = "app-${var.name_prefix}-${local.suffix}"
  }

  tags = merge({
    managed-by = "terraform"
    repo       = "benoitnvl/scandula"
    component  = "azure-ipam"
  }, var.tags)

  # Subscription offer ids (quotaId) of credit and trial subscriptions.
  credit_offer_pattern = "^(MSDN|FreeTrial|AzurePass|Sponsored|DreamSpark|Students|AzureForStudents)"
}
