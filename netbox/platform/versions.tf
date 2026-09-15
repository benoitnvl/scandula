terraform {
  # 1.9+ for validation blocks that reference other variables.
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.4"
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

  # Remote state in Azure Storage, its own container. Partial config: the rest comes
  # from backend.hcl (gitignored — see backend.hcl.example and netbox/README.md).
  # ⚠ This state holds the NetBox database password, the Django SECRET_KEY and the
  # Redis access key. Treat it as a secret store.
  backend "azurerm" {}
}
