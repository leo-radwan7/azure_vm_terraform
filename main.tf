# ==============================================================
# ROOT MODULE
# ==============================================================
# This is the entry point — what Terraform runs when you type
# "terraform apply". It creates the shared infrastructure
# (resource group, network) and then calls our VM module
# once for each VM we want.
# ==============================================================

terraform {
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

# ==============================================================
# SHARED INFRASTRUCTURE
# ==============================================================
# These resources are created once and shared by all VMs.
# This is why they live here in the root module, not inside
# the VM module — all three VMs need the SAME network.
# ==============================================================

resource "azurerm_resource_group" "rg" {
  name     = "k3s-cluster-rg"
  location = "West US 2"
}

resource "azurerm_virtual_network" "vnet" {
  name                = "k3s-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_subnet" "subnet" {
  name                 = "k3s-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

# ==============================================================
# VM INSTANCES
# ==============================================================
# Here's where the module pays off. We call it three times
# with different names, and each call creates a complete VM
# with its own NIC, public IP, NSG, etc.
#
# The syntax is:
#   module "<label>" {
#     source = "<path to module directory>"
#     <variable> = <value>
#   }
#
# "source" tells Terraform where the module code lives.
# Everything else maps to the variables we defined in
# modules/vm/variables.tf.
# ==============================================================

# The subnet CIDR is used in security rules. We define it as a local
# so it's easy to reference without repeating the string.
locals {
  subnet_cidr = "10.0.1.0/24"
}

# --- K3s join token ---
# random_password generates a cryptographically random string.
# We use it as the shared secret between server and agents.
# It's stored in Terraform state (so it persists across runs)
# but never needs to leave this config.
resource "random_password" "k3s_token" {
  length  = 32
  special = false # Keep it alphanumeric — avoids shell escaping headaches
}

# ==============================================================
# SERVER
# ==============================================================
module "server" {
  source = "./modules/vm"

  vm_name             = "k3s-server"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  subnet_id           = azurerm_subnet.subnet.id
  subnet_cidr         = local.subnet_cidr
  vm_size             = "Standard_F2als_v7"
  extra_open_ports    = [6443, 80, 443, 30443]

  # templatefile() reads a file and replaces ${...} placeholders
  # with the values we provide in the second argument (a map).
  #
  # base64encode() converts the rendered script to base64,
  # which is the format Azure expects for custom_data.
  #
  # So the flow is:
  #   1. templatefile() renders the script with the real token
  #   2. base64encode() converts it to base64
  #   3. Azure receives it and passes it to cloud-init
  #   4. cloud-init decodes it and runs it as root
  custom_data = base64encode(templatefile("${path.module}/scripts/install-k3s-server.sh", {
    k3s_token = random_password.k3s_token.result
  }))
}

# ==============================================================
# AGENTS
# ==============================================================
# Both agents use the same script template but need two values:
#   - k3s_token          → same token as the server
#   - server_private_ip  → so they know where to connect
#
# depends_on ensures Terraform creates the server VM BEFORE
# the agent VMs. Without it, Terraform would create all three
# in parallel (because there's no direct data dependency
# between the module calls for the agents and the server).
#
# Note: depends_on only guarantees the server VM *exists* in
# Azure. The agent script's retry loop handles waiting for K3s
# to actually be running.
module "agent1" {
  source = "./modules/vm"

  vm_name             = "k3s-agent-1"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  subnet_id           = azurerm_subnet.subnet.id
  subnet_cidr         = local.subnet_cidr

  custom_data = base64encode(templatefile("${path.module}/scripts/install-k3s-agent.sh", {
    k3s_token         = random_password.k3s_token.result
    server_private_ip = module.server.private_ip_address
  }))

  depends_on = [module.server]
}

module "agent2" {
  source = "./modules/vm"

  vm_name             = "k3s-agent-2"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  subnet_id           = azurerm_subnet.subnet.id
  subnet_cidr         = local.subnet_cidr

  custom_data = base64encode(templatefile("${path.module}/scripts/install-k3s-agent.sh", {
    k3s_token         = random_password.k3s_token.result
    server_private_ip = module.server.private_ip_address
  }))

  depends_on = [module.server]
}

# ==============================================================
# OUTPUTS
# ==============================================================
# These print to your terminal after "terraform apply" finishes.
# We access module outputs with: module.<label>.<output_name>
# ==============================================================

output "server_public_ip" {
  value = module.server.public_ip_address
}

output "server_private_ip" {
  value = module.server.private_ip_address
}

output "agent1_public_ip" {
  value = module.agent1.public_ip_address
}

output "agent2_public_ip" {
  value = module.agent2.public_ip_address
}
