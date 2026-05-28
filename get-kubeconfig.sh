#!/bin/bash
# =============================================================
# Fetch the cluster kubeconfig to a local ./kubeconfig file
# =============================================================
# After "terraform apply", run this script, then:
#
#   export KUBECONFIG=$PWD/kubeconfig
#   kubectl get nodes
#
# What it does (the manual steps, automated):
#   1. Reads the server's public IP from terraform output.
#   2. SSHes to the server and reads K3s's kubeconfig
#      (/etc/rancher/k3s/k3s.yaml, root-only).
#   3. Rewrites the API address from 127.0.0.1 (which only works
#      ON the server) to the server's public IP (which works from
#      your laptop — the cert already trusts it via --tls-san).
#   4. Writes the result to ./kubeconfig with 0600 permissions.
#
# Writing to ./kubeconfig (not ~/.kube/config) keeps this cluster
# isolated — it won't clobber any other clusters you have set up.
# =============================================================
set -euo pipefail

# --- Config (override via env vars if your setup differs) ---
SSH_KEY="${SSH_KEY:-$HOME/.ssh/azure_vm_key}"
SSH_USER="${SSH_USER:-azureuser}"
OUTPUT="${OUTPUT:-./kubeconfig}"

# --- 1. Get the server's public IP from Terraform ---
# -raw prints the bare value (no quotes/JSON) so it's usable directly.
echo "Reading server public IP from terraform output..."
SERVER_IP="$(terraform output -raw server_public_ip)"

if [ -z "$SERVER_IP" ]; then
  echo "ERROR: terraform output returned no server_public_ip." >&2
  echo "Make sure you've run 'terraform apply' and are in project_files/." >&2
  exit 1
fi
echo "Server public IP: $SERVER_IP"

# --- 2 & 3. Fetch the kubeconfig and rewrite the API address ---
# StrictHostKeyChecking=no + UserKnownHostsFile=/dev/null: the server's
# public IP is reassigned on every apply, so its host key changes and
# would otherwise trigger a "host identification changed" error. Fine
# for a throwaway lab cluster; you'd NOT do this for production hosts.
echo "Fetching kubeconfig from the server..."
ssh -i "$SSH_KEY" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  "$SSH_USER@$SERVER_IP" \
  "sudo cat /etc/rancher/k3s/k3s.yaml" \
  | sed "s|https://127.0.0.1:6443|https://$SERVER_IP:6443|" \
  > "$OUTPUT"

# --- 4. Lock down permissions (kubeconfig holds admin credentials) ---
chmod 600 "$OUTPUT"

echo ""
echo "Wrote kubeconfig to $OUTPUT"
echo "To use it:"
echo "  export KUBECONFIG=\$PWD/$OUTPUT"
echo "  kubectl get nodes"
