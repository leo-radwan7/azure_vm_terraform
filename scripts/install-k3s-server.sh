#!/bin/bash
# =============================================================
# K3s SERVER install script
# =============================================================
# This script runs via cloud-init on first boot.
# Terraform injects variables using templatefile() — anything
# wrapped in dollar-braces is replaced BEFORE the script reaches the VM.
#
# Terraform-injected variables:
#   k3s_token  — the shared secret agents use to join
# =============================================================
set -e   # Exit immediately if any command fails

# ---- Step 1: Get our public IP ----
# We need the public IP for --tls-san below (so kubectl from
# your laptop can connect over the public IP without TLS errors).
#
# Strategy: try Azure IMDS first (local, no external dependency).
# If IMDS doesn't return a public IP after 15 attempts (~30s),
# fall back to an external IP-lookup service (ifconfig.me).
#
# WHY IMDS CAN FAIL:
# IMDS (Instance Metadata Service, 169.254.169.254) is a local
# HTTP endpoint every Azure VM can query to learn about itself.
# However, the public-IP field can be empty due to:
#   - A race at boot (public IP not yet attached to the NIC)
#   - Standard SKU public IPs not always reported by IMDS
#   - Subscription state changes affecting metadata propagation
#
# WHY THE FALLBACK WORKS:
# ifconfig.me is an external service that returns the public IP
# the request came from. Since the VM has internet access (we
# download K3s and ArgoCD later in this script), this is reliable.
# The only cost is a dependency on an external service, which is
# why we try IMDS first.

PUBLIC_IP=""

# Attempt 1: Azure IMDS (15 attempts, ~30s)
echo "Trying to get public IP from Azure IMDS..."
for attempt in $(seq 1 15); do
  PUBLIC_IP=$(curl -sf --max-time 5 -H Metadata:true --noproxy "*" \
    "http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/publicIpAddress?api-version=2021-02-01&format=text" \
    || true)

  if [ -n "$PUBLIC_IP" ]; then
    echo "Got public IP from IMDS on attempt $attempt: $PUBLIC_IP"
    break
  fi

  echo "IMDS returned empty (attempt $attempt/15), sleeping 2s..."
  sleep 2
done

# Attempt 2: external IP-lookup service (fallback)
if [ -z "$PUBLIC_IP" ]; then
  echo "IMDS did not return a public IP. Falling back to ifconfig.me..."
  PUBLIC_IP=$(curl -sf --max-time 10 https://ifconfig.me || true)

  if [ -n "$PUBLIC_IP" ]; then
    echo "Got public IP from ifconfig.me: $PUBLIC_IP"
  fi
fi

# Hard fail if neither method worked
if [ -z "$PUBLIC_IP" ]; then
  echo "ERROR: Could not determine public IP from IMDS or ifconfig.me." >&2
  echo "Aborting K3s install -- the cert would be missing the public IP SAN." >&2
  exit 1
fi

# ---- Step 2: Install K3s in server mode ----
# The K3s install script (get.k3s.io) detects the OS and installs
# the right binary. Environment variables configure the install:
#
#   K3S_TOKEN  — the shared secret. Agents must present this
#                same token to join the cluster.
#
# The "sh -s - server" part:
#   sh -s     = read the script from stdin (piped from curl)
#   -         = separator between sh flags and script arguments
#   server    = tells K3s to run in server (control-plane) mode
#
# --tls-san flag:
#   K3s generates a TLS certificate for its API server. By default,
#   the cert only covers the private IP and 127.0.0.1. If you try
#   to connect from your laptop via the public IP, kubectl will
#   reject the cert because the IP doesn't match.
#   --tls-san adds our public IP to the certificate's Subject
#   Alternative Names, so kubectl trusts it.
#
curl -sfL https://get.k3s.io | K3S_TOKEN="${k3s_token}" sh -s - server \
  --tls-san "$PUBLIC_IP"

echo "K3s server install complete."

# ---- Step 3: Install ArgoCD ----
# ArgoCD is a GitOps controller that runs inside the cluster,
# watches a git repo, and automatically applies Kubernetes
# manifests when they change. We install it here in cloud-init
# so that by the time the VM is "done booting," ArgoCD is ready
# to manage app deployment with zero manual steps.

# 3a. Tell kubectl where to find the kubeconfig.
# K3s writes it to /etc/rancher/k3s/k3s.yaml (root-only).
# Cloud-init runs as root, so this path works.
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# 3b. Wait for the K3s API server to accept requests.
# After K3s installs, its API server takes a few seconds to
# start. kubectl commands will fail during that window. We
# poll until "kubectl get nodes" succeeds, same retry pattern
# as the IMDS fix in Step 1.
echo "Waiting for K3s API server to be ready..."
for attempt in $(seq 1 30); do
  if kubectl get nodes >/dev/null 2>&1; then
    echo "K3s API is ready (attempt $attempt)."
    break
  fi
  echo "K3s API not ready yet (attempt $attempt/30), sleeping 2s..."
  sleep 2
done

# 3c. Create the argocd namespace and apply the install manifest.
# The URL points to the latest stable ArgoCD release -- a single
# YAML file containing all the resources ArgoCD needs: custom
# resource definitions, Deployments, Services, RBAC roles, etc.
#
# --server-side=true is required because recent ArgoCD versions
# have CRDs so large that the default client-side apply exceeds
# Kubernetes' 256KB annotation limit. Server-side apply uses
# "managed fields" instead of the last-applied-configuration
# annotation, avoiding the size limit entirely.
echo "Installing ArgoCD..."
kubectl create namespace argocd
kubectl apply -n argocd --server-side=true -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 3d. Wait for ArgoCD's API/dashboard component to be ready.
# "rollout status" blocks until the Deployment's pods are all
# Running and Ready, or until the timeout. ArgoCD typically
# takes 30-60s to start on small VMs.
echo "Waiting for ArgoCD server to be ready..."
kubectl -n argocd rollout status deployment/argocd-server --timeout=180s

echo "ArgoCD install complete."

# ---- Step 3e: Expose the ArgoCD dashboard via NodePort ----
# By default, the argocd-server Service is ClusterIP (internal
# only). We patch it to NodePort so the web dashboard is
# reachable from a browser at https://<server_public_ip>:30443.
#
# "kubectl patch" modifies a live resource without rewriting
# the whole YAML. The --type=merge flag says "JSON merge patch:
# merge this JSON snippet into the existing spec."
#
# 30443 is in the allowed NodePort range (30000-32767) and is
# easy to remember (ArgoCD serves on 443 internally).
#
# ArgoCD serves HTTPS by default with a self-signed cert, so
# the browser will show a security warning -- that's expected.
kubectl patch svc argocd-server -n argocd --type=merge \
  -p '{"spec": {"type": "NodePort", "ports": [{"port": 443, "nodePort": 30443}]}}'

echo "ArgoCD dashboard exposed on NodePort 30443."

# ---- Step 4: Create the ArgoCD Application ----
# This tells ArgoCD: "watch the k8s/ directory in our GitHub
# repo and deploy whatever manifests you find there." ArgoCD
# then clones the repo, reads the YAMLs, and applies them --
# the same thing "kubectl apply -f k8s/" does, but automated
# and continuously reconciled.
#
# We curl the Application manifest from GitHub rather than
# embedding it as a heredoc. This way the YAML lives in one
# place (the repo), and if we change it later, we only update
# one file.
echo "Creating ArgoCD Application for counter-app..."
kubectl apply -f https://raw.githubusercontent.com/leo-radwan7/azure_vm_terraform/main/argocd/counter-app.yaml

echo "ArgoCD Application created. ArgoCD will now deploy the app from git."
