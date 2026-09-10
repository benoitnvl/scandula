# Credentials come from the environment, never from this repo:
#   ARM_SUBSCRIPTION_ID  the connectivity subscription (required for plan/apply)
#   az login locally — or ARM_USE_OIDC / ARM_CLIENT_ID / ARM_TENANT_ID in CI later.
#
# azurerm 5.x registers no resource providers by default. Everything here is
# Microsoft.Network, which docs/bootstrap.md registers once by hand, so the deploy
# identity doesn't need subscription-wide register rights.
provider "azurerm" {
  features {}
}
