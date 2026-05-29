# ==============================================================
# MODULE INPUTS (variables)
# ==============================================================
# Each "variable" block declares one parameter that the caller
# MUST (or can optionally) pass when using this module.
#
# Think of these like function parameters:
#   module "server" {
#     vm_name = "k3s-server"   ← this value lands in var.vm_name
#   }
# ==============================================================

# ---------- Identity & placement ----------

variable "vm_name" {
  description = "Name for the VM and its associated resources (NIC, IP, etc.)"
  type        = string
  # No default → the caller MUST provide this
}

variable "resource_group_name" {
  description = "Name of the resource group to place resources in"
  type        = string
}

variable "location" {
  description = "Azure region (e.g. West US 2)"
  type        = string
}

# ---------- Networking ----------

variable "subnet_id" {
  description = "ID of the subnet this VM's NIC will attach to"
  type        = string
  # We pass the ID (not the name) because that's what azurerm_network_interface needs.
  # The root module creates the subnet and hands us its .id
}

# ---------- Networking (security) ----------

variable "subnet_cidr" {
  description = "The CIDR block of the subnet (e.g. 10.0.1.0/24) — used to allow all intra-cluster traffic"
  type        = string
  # We need this as a separate variable because subnet_id is an opaque ID string
  # like "/subscriptions/.../subnets/k3s-subnet". You can't extract the CIDR
  # from that — so we pass it explicitly.
}

variable "extra_open_ports" {
  description = "Additional ports to open from the internet (e.g. [6443, 80, 443] for the server)"
  type        = list(number)
  default     = []
  # Defaults to empty — agents don't need any extra ports.
  # The server will pass [6443, 80, 443] to expose the K3s API and web traffic.
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed to SSH (port 22) to this VM, e.g. your home IP as x.x.x.x/32"
  type        = string
}

# ---------- VM sizing & auth ----------

variable "vm_size" {
  description = "Azure VM size (e.g. Standard_B2s, Standard_D2als_v7)"
  type        = string
  default     = "Standard_F1als_v7"
  # A default means this is optional — if the caller doesn't set it,
  # we use this value. Good for settings that are usually the same.
}

variable "admin_username" {
  description = "SSH username for the VM"
  type        = string
  default     = "azureuser"
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key file on your local machine"
  type        = string
  default     = "~/.ssh/azure_vm_key.pub"
}

# ---------- Provisioning ----------

variable "custom_data" {
  description = "Base64-encoded cloud-init script to run on first boot"
  type        = string
  default     = null
  # null means "don't pass anything" — Azure just boots normally.
  # When set, Azure hands this to cloud-init, which runs it as root.
}
