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
