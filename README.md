# K3s Cluster on Azure — Terraform + ArgoCD

Stands up a 3-node K3s Kubernetes cluster on Azure VMs (1 server + 2 agents) with
a reusable Terraform module, installs K3s via cloud-init, and uses ArgoCD to deploy
a small demo counter app from the `k8s/` directory.

## Prerequisites

- **Azure CLI**, logged in: `az login`
- **Terraform** >= 1.0
- **SSH key** at `~/.ssh/azure_vm_key` / `~/.ssh/azure_vm_key.pub`
- Access to the remote state storage account (`terraform-state-rg` / `tfstatek3sleo`),
  or point the backend in `providers.tf` at your own.

## Setup

Create `terraform.tfvars` (gitignored) with the IP allowed to SSH the VMs:

```hcl
allowed_ssh_cidr = "x.x.x.x/32"   # your public IP — find it with: curl -4 ifconfig.me
```

## Deploy

```bash
terraform init      # connects to the Azure remote state backend
terraform apply     # creates the VMs + installs K3s and ArgoCD
```

## Verify

```bash
./get-kubeconfig.sh                 # fetches kubeconfig from the server
export KUBECONFIG=$PWD/kubeconfig
kubectl get nodes                   # → 3 Ready nodes (k3s-server, k3s-agent-1, k3s-agent-2)
```

## Access

```bash
terraform output server_public_ip
```

- **Demo app:** `http://<server_public_ip>/`
- **ArgoCD dashboard:** `http://<server_public_ip>:30443` (user `admin`; password in `llm_context.md`)

## Notes

- SSH is restricted to `allowed_ssh_cidr`. If your IP changes you'll be locked out —
  update `terraform.tfvars` and re-`apply`.
- The Redis password in `k8s/10-redis-secret.yaml` is **plaintext for learning** — see
  the comment in that file.
- Full architecture, design decisions, and troubleshooting live in `llm_context.md`.
