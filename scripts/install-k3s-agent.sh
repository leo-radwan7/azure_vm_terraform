#!/bin/bash
# =============================================================
# K3s AGENT install script
# =============================================================
# This script runs via cloud-init on first boot.
#
# Terraform-injected variables:
#   k3s_token          — the shared secret to join the cluster
#   server_private_ip  — the server's private IP on the subnet
# =============================================================
set -e

# ---- Step 1: Wait for the server to be ready ----
# Even though Terraform creates the server VM first (via depends_on),
# the VM being "created" in Azure doesn't mean K3s is running.
# The server still needs a minute or two to:
#   1. Boot the OS
#   2. Run cloud-init
#   3. Download and install K3s
#   4. Start the K3s API server
#
# So we poll the server's API endpoint until it responds.
# curl flags:
#   -s  = silent (no progress bar)
#   -k  = ignore TLS cert errors (the server's cert may not be
#          fully ready, and we don't have the CA cert yet)
#   -o /dev/null = discard response body, we just care about exit code
#
SECONDS=0       # Bash built-in — automatically increments every second
TIMEOUT=600     # 10 minutes

echo "Waiting for K3s server at ${server_private_ip}:6443..."
until curl -sk -o /dev/null https://${server_private_ip}:6443; do
  if [ $SECONDS -ge $TIMEOUT ]; then
    echo "ERROR: Server did not become ready within $TIMEOUT seconds. Giving up."
    exit 1
  fi
  echo "  Server not ready yet ($SECONDS seconds elapsed), retrying in 10s..."
  sleep 10
done
echo "Server is ready! Joining cluster..."

# ---- Step 2: Install K3s in agent mode ----
# Two environment variables tell the installer this is an agent:
#
#   K3S_URL    — where to find the server. Uses the PRIVATE IP
#                because both VMs are on the same 10.0.1.0/24
#                subnet. Private traffic is free and fast.
#
#   K3S_TOKEN  — the same token the server was started with.
#                This is how the agent authenticates.
#
# Note: no "server" argument after the "--" this time.
# When K3S_URL is set, the installer defaults to agent mode.
#
curl -sfL https://get.k3s.io | K3S_URL="https://${server_private_ip}:6443" K3S_TOKEN="${k3s_token}" sh -

echo "K3s agent install complete."
