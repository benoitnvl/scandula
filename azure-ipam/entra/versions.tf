terraform {
  # 1.9+ for validation blocks that reference other variables.
  required_version = ">= 1.9"

  required_providers {
    azuread = {
      source = "hashicorp/azuread"
      # The split application resources (registration, identifier URI, permission
      # scope, api access, known clients, pre-authorized) were checked at v3.9.0.
      version = "~> 3.9"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }

  # Partial config: the rest comes from backend.hcl (gitignored; see
  # backend.hcl.example). CI and tests run with `init -backend=false`.
  backend "azurerm" {}
}
