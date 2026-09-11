terraform {
  # 1.9+ for validation blocks that reference other variables.
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      # linux_web_app zip_deploy_file, key_vault rbac_authorization_enabled and the
      # cosmosdb_* arguments were checked against the v5.4.0 schema.
      version = "~> 5.4"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.9"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.14"
    }
  }

  # Partial config: the rest comes from backend.hcl (gitignored; see
  # backend.hcl.example). CI and tests run with `init -backend=false`.
  backend "azurerm" {}
}
