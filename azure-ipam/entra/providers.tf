# Part 1 is run by an Aberdeen tenant administrator, signed in with `az login` as:
#   - a Global Administrator, for the tenant-wide (AllPrincipals) consent grants, and
#   - someone who can assign roles at the management group the engine reads (the
#     tenant root by default): Owner, User Access Administrator, or a custom role
#     with Microsoft.Authorization/roleAssignments/write.
#
# azurerm needs a subscription (ARM_SUBSCRIPTION_ID), though the only Azure resource
# here is a management-group role assignment: any subscription the admin can see.
provider "azuread" {}

provider "azurerm" {
  features {}
}
