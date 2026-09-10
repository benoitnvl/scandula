terraform {
  # 1.9+ for validation blocks that reference other variables (regions → root prefix).
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      # IPAM pools, static CIDRs and `ip_address_pool` on VNets and subnets were
      # checked against the provider docs at v5.4.0.
      version = "~> 5.4"
    }
  }

  # Remote state in Azure Storage. Partial config: the rest comes from backend.hcl
  # (gitignored — see backend.hcl.example and docs/bootstrap.md). CI and tests run
  # with `init -backend=false` and never touch it.
  backend "azurerm" {}
}
