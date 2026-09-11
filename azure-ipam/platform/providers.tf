# Part 2 is applied only by GitHub Actions (.github/workflows/azure-ipam-deploy.yaml),
# as the platform CI identity over OIDC, against the paid subscription that hosts
# Azure IPAM. That identity holds (azure-ipam/README.md):
#   - Owner on the subscription, because it creates role assignments;
#   - Graph Application.ReadWrite.OwnedBy, and ownership of both app registrations
#     (part 1's platform_owner_object_ids). That's what lets it create the engine's
#     secret and set the UI's redirect URI.
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
