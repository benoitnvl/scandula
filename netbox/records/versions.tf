terraform {
  required_version = ">= 1.9"

  required_providers {
    netbox = {
      source = "e-breuninger/netbox"
      # 5.8.0 is the newest release; its tested NetBox ceiling is v4.6.5, which is
      # what netbox/platform/release.json pins. Bump the two together.
      #
      # ⚠ Provider 6.0.0 will be mostly auto-generated rather than hand-maintained
      # (announced in the 5.8.0 release notes), so expect a real migration there,
      # not a version bump.
      version = "~> 5.8"
    }
  }

  # Remote state in Azure Storage, its own container. No secret lives in this state,
  # but the API token used to write it is an admin token — keep the container
  # readable by the same people as the rest.
  backend "azurerm" {}
}
