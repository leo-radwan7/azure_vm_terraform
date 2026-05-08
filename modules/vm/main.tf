# ==============================================================
# VM MODULE — creates one complete VM with networking
# ==============================================================
# This module creates:
#   1. A public IP address
#   2. A network security group (firewall rules)
#   3. A network interface (connects the VM to the subnet)
#   4. The NSG ↔ NIC association
#   5. The Linux VM itself
#
# Every resource uses var.vm_name in its name so that when we
# call this module three times, the resource names don't collide.
# ==============================================================

# --- 1. Public IP ---
# Each VM gets its own public IP so we can SSH into it and
# (for the server) access the K3s API / apps from outside.
resource "azurerm_public_ip" "pip" {
  name                = "${var.vm_name}-pip"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

# --- 2. Network Security Group (firewall) ---
# Controls which traffic is allowed to reach the VM.
#
# We define three layers of rules:
#   a) SSH from anywhere          (all VMs need this)
#   b) All traffic from subnet    (all VMs need this — K3s inter-node)
#   c) Extra ports from internet  (only VMs that need them, via variable)
#
resource "azurerm_network_security_group" "nsg" {
  name                = "${var.vm_name}-nsg"
  location            = var.location
  resource_group_name = var.resource_group_name

  # Rule (a): Allow SSH from anywhere
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

  # Rule (b): Allow ALL traffic from within the subnet
  # This is the key rule for K3s. Instead of listing every port
  # (6443, 8472, 10250, etc.), we say "anything from 10.0.1.0/24
  # is allowed." This works because all three VMs live on this
  # subnet, and we trust intra-cluster traffic.
  security_rule {
    name                       = "allow-intra-subnet"
    priority                   = 1000
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = var.subnet_cidr
    destination_address_prefix = "*"
  }

  # Rule (c): Extra ports open to the internet
  # This uses a "dynamic block" — a Terraform feature that generates
  # repeated nested blocks from a list. It's like a for-loop inside
  # a resource.
  #
  # If extra_open_ports = [6443, 80, 443], this generates three
  # security_rule blocks. If it's [] (the default), it generates none.
  #
  # dynamic "<block_name>" iterates over a collection.
  # "content" defines what each generated block looks like.
  # Each item is accessed via <block_name>.value
  dynamic "security_rule" {
    for_each = var.extra_open_ports
    content {
      name                       = "allow-port-${security_rule.value}"
      priority                   = 1100 + security_rule.key # .key is the index (0, 1, 2...)
      direction                  = "Inbound"                # so priorities become 1100, 1101, 1102
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = tostring(security_rule.value)
      source_address_prefix      = "*"
      destination_address_prefix = "*"
    }
  }
}

# --- 3. Network Interface ---
# The NIC is what actually plugs the VM into the subnet.
# It gets a private IP (automatically assigned from the subnet range)
# and we attach the public IP to it as well.
resource "azurerm_network_interface" "nic" {
  name                = "${var.vm_name}-nic"
  location            = var.location
  resource_group_name = var.resource_group_name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.pip.id
  }
}

# --- 4. Associate NSG with NIC ---
# Azure requires an explicit association resource to link
# a security group to a network interface. This is a common
# pattern in Azure — many relationships need their own resource.
resource "azurerm_network_interface_security_group_association" "nic_nsg" {
  network_interface_id      = azurerm_network_interface.nic.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

# --- 5. The VM itself ---
resource "azurerm_linux_virtual_machine" "vm" {
  name                            = var.vm_name
  resource_group_name             = var.resource_group_name
  location                        = var.location
  size                            = var.vm_size
  admin_username                  = var.admin_username
  disable_password_authentication = true
  custom_data                     = var.custom_data

  network_interface_ids = [
    azurerm_network_interface.nic.id
  ]

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(var.ssh_public_key_path)
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
