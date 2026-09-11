# Part 2 is run by us, against the paid subscription that hosts Azure IPAM:
#   ARM_SUBSCRIPTION_ID  that subscription. Owner, because it creates role assignments.
#   az login             as an identity in part 1's platform_owner_object_ids, so it can
#                        create the engine's secret and set the UI's redirect URI.
#
# azurerm 5.x registers no resource providers by default: register Microsoft.Web,
# Microsoft.DocumentDB, Microsoft.KeyVault, Microsoft.ManagedIdentity,
# Microsoft.OperationalInsights and Microsoft.Insights once (azure-ipam/README.md).
provider "azurerm" {
  features {
    key_vault {
      # The vault has purge protection, so a purge on destroy could only fail.
      purge_soft_delete_on_destroy = false
    }
  }
}

provider "azuread" {}
