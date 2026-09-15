terraform {
  # 1.9+ for validation blocks that reference other variables (subnets → the VNet size).
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      # `ip_address_pool` on azurerm_virtual_network and azurerm_subnet, checked
      # against the provider schema at v5.5.0.
      version = "~> 5.4"
    }
  }
}

# No backend block on purpose: this root is never applied from scandula, it's a
# pattern to copy into the repo that owns the spoke. Add your own state there —
# scandula's roots use a partial `backend "azurerm" {}` plus a gitignored
# backend.hcl (docs/bootstrap.md).
