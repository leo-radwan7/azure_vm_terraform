# Tell Terraform we are using Azure
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
}

# Create a resource group (a container that holds all our Azure resources)
resource "azurerm_resource_group" "rg" {
  name     = "my-vm-resource-group"
  location = "West US 2"
}

# Create a virtual network (a private network for our VM to live in)
resource "azurerm_virtual_network" "vnet" {
  name                = "my-vm-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

# Create a subnet (a smaller section within our virtual network)
resource "azurerm_subnet" "subnet" {
  name                 = "my-vm-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

# Create a public IP address (so we can reach the VM from the internet)
resource "azurerm_public_ip" "pip" {
  name                = "my-vm-public-ip"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

# Create a network security group (a firewall that controls traffic)
resource "azurerm_network_security_group" "nsg" {
  name                = "my-vm-nsg"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  # Allow SSH traffic on port 22
  security_rule {
    name                       = "allow-ssh"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

# Create a network interface (connects the VM to the network)
resource "azurerm_network_interface" "nic" {
  name                = "my-vm-nic"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.pip.id
  }
}

# Attach the security group to the network interface
resource "azurerm_network_interface_security_group_association" "nic_nsg" {
  network_interface_id      = azurerm_network_interface.nic.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

# Create the virtual machine
resource "azurerm_linux_virtual_machine" "vm" {
  name                = "my-azure-vm"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  size                            = "Standard_D2als_v7"
  admin_username                  = "azureuser"
  disable_password_authentication = true
  zone                            = "1"

  network_interface_ids = [
    azurerm_network_interface.nic.id
  ]

  admin_ssh_key {
    username   = "azureuser"
    public_key = file("~/.ssh/azure_vm_key.pub")
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }
}

# Output the public IP so we know where to SSH into
output "public_ip_address" {
  value = azurerm_public_ip.pip.ip_address
}
