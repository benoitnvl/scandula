# Part 1 is applied only by GitHub Actions (.github/workflows/azure-ipam-deploy.yaml),
# as the entra CI identity over OIDC. ARM_USE_OIDC, ARM_CLIENT_ID, ARM_TENANT_ID and
# ARM_SUBSCRIPTION_ID come from the workflow. That identity holds (azure-ipam/README.md):
#   - Graph Application.ReadWrite.All, plus Directory.ReadWrite.All for the tenant-wide
#     (AllPrincipals) consent grants;
#   - Role Based Access Control Administrator at the management group the engine reads
#     (the tenant root by default), limited to assigning Reader.
#
# azurerm needs a subscription, though the only Azure resource here is a
# management-group role assignment. A local, read-only plan can use `az login` instead.
provider "azuread" {}

provider "azurerm" {
  features {}
}
