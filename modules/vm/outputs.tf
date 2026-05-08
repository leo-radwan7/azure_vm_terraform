# ==============================================================
# MODULE OUTPUTS
# ==============================================================
# Outputs are the "return values" of a module. After Terraform
# creates all the resources, these values become available to
# whoever called the module.
#
# Example — in the root module you'd access these as:
#   module.server.public_ip_address
#   module.server.private_ip_address
# ==============================================================

output "public_ip_address" {
  description = "The public IP assigned to this VM"
  value       = azurerm_public_ip.pip.ip_address
}

output "private_ip_address" {
  description = "The private IP assigned to this VM (used for intra-cluster communication)"
  value       = azurerm_network_interface.nic.private_ip_address
  # This is the IP on the 10.0.1.x subnet. The K3s agents will
  # use the server's private IP to join the cluster — traffic
  # stays inside the Azure virtual network, which is faster
  # and doesn't cost egress fees.
}

output "vm_id" {
  description = "The Azure resource ID of the VM"
  value       = azurerm_linux_virtual_machine.vm.id
}
