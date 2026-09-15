# Credentials come from the environment, never from this repo:
#   ARM_SUBSCRIPTION_ID  the subscription NetBox runs in
#   az login locally, or ARM_USE_OIDC / ARM_CLIENT_ID / ARM_TENANT_ID in CI.
provider "azurerm" {
  features {
    key_vault {
      # A soft-deleted vault of the same name blocks a rebuild otherwise.
      recover_soft_deleted_key_vaults = true
      purge_soft_delete_on_destroy    = false
    }
  }
}
