# Credentials come from the environment, never from a repo:
#   ARM_SUBSCRIPTION_ID  the subscription this spoke lives in — which is NOT
#                        scandula's connectivity subscription. A spoke is
#                        deployed by its own team, into its own subscription.
#
# The IPAM pool and the vWAN hub live in the connectivity subscription. Both are
# referenced by resource id across the subscription boundary, so the identity
# running this needs a role on them — see README.md ("What you need first").
provider "azurerm" {
  features {}
}
