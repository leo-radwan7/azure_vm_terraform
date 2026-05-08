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

# ---- Step 1: Get our public IP from Azure IMDS (with retry) ----
# IMDS (Instance Metadata Service) is a special HTTP endpoint
# available to every Azure VM at 169.254.169.254. The VM can
# query it to learn about itself -- its name, IPs, region, etc.
# No authentication needed, it only works from inside the VM.
#
# We need the public IP for --tls-san below.
#
# WHY THE LOOP:
# Cloud-init runs early in boot. Azure attaches the public IP and
# propagates it into IMDS asynchronously. There is a window
# (usually under 10s, occasionally longer) where IMDS responds
# 200 OK but the public-IP field is empty. A single un-retried
# curl can land in that window, producing an empty PUBLIC_IP --
# which then makes the --tls-san flag below silently no-op,
# leaving the K3s API cert without the public IP in its SANs
# and breaking remote kubectl.
#
# Fix: poll IMDS until we get a non-empty answer, with a hard
# cap so we fail loudly if something is genuinely broken instead
# of producing a half-working cluster.
PUBLIC_IP=""
for attempt in $(seq 1 30); do
  # -f           : curl returns non-zero on HTTP errors
  # --max-time 5 : cap one attempt so a hung request can't stall
  # || true      : suppress set -e on transient failure so we can retry
  PUBLIC_IP=$(curl -sf --max-time 5 -H Metadata:true --noproxy "*" \
    "http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/publicIpAddress?api-version=2021-02-01&format=text" \
    || true)

  if [ -n "$PUBLIC_IP" ]; then
    echo "Got public IP from IMDS on attempt $attempt: $PUBLIC_IP"
    break
  fi

  echo "IMDS returned empty public IP (attempt $attempt/30), sleeping 2s..."
  sleep 2
done

if [ -z "$PUBLIC_IP" ]; then
  echo "ERROR: IMDS did not return a public IP after 30 attempts (~60s)." >&2
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
