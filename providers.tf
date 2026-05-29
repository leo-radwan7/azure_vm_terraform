terraform {
  required_version = ">= 1.0"

  # Remote state in Azure Blob Storage. The storage account, resource
  # group, and container were created once by hand (Azure CLI) and live
  # OUTSIDE this Terraform config — in a separate resource group — so
  # "terraform destroy" can never delete the state it depends on.
  # State locking is handled natively by Azure (blob lease).
  backend "azurerm" {
    resource_group_name  = "terraform-state-rg"
    storage_account_name = "tfstatek3sleo"
    container_name       = "tfstate"
    key                  = "k3s-cluster.tfstate"
  }

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    # We need the "random" provider to generate the K3s token.
    # Providers are plugins — each one knows how to talk to a
    # specific API (Azure, AWS, random number generation, etc.)
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
}
