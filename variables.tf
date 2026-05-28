# ==============================================================
# ROOT MODULE INPUTS
# ==============================================================

variable "allowed_ssh_cidr" {
  description = "CIDR allowed to SSH (port 22) to the VMs, e.g. your home IP as x.x.x.x/32. Set in terraform.tfvars (gitignored) so it stays out of version control."
  type        = string
  # No default — Terraform will require a value, keeping a real IP
  # out of the committed config.
}
