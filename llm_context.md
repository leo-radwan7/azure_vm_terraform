# LLM Context: K3s Cluster on Azure with Terraform + Counter App Bonus

## Project Goal

Turn a single-VM Terraform config into a reusable module, use it to stand up three Azure VMs (1 server, 2 agents), provision them as a working K3s Kubernetes cluster via cloud-init scripts, and deploy a small containerized web app to that cluster as a learning exercise.

## Current Status

**Infrastructure (Terraform):**
- Terraform config is complete and currently applied.
- All three VMs created, K3s installed via cloud-init, cluster verified working.
- `kubectl get nodes` returns three Ready nodes running K3s v1.34.6+k3s1.

**Bonus task (deploy an app reachable from a browser):** ✅ complete.
- ✅ Stage 1: Wrote Python Flask API (`app/app.py`) — single endpoint that increments a Redis counter and returns JSON with the pod hostname.
- ✅ Stage 2: Wrote `app/Dockerfile` and `app/.dockerignore`. Single-stage build on `python:3.12-slim`, runs `gunicorn` with 2 workers on port 5000.
- ✅ Stage 3: Built image for `linux/amd64` via `docker buildx` (cross-compiled from arm64 Mac) and pushed to Docker Hub as `leodvethings/k3s-counter-api:v1`.
- ✅ Stage 4.0: Configured `kubectl` on the user's Mac to talk to the cluster over its public IP (kubeconfig at `~/.kube/config`).
- ✅ Stage 4.1: Created the `counter-app` Namespace (`k8s/00-namespace.yaml`).
- ✅ Stage 4.2: Created the Secret `redis-secret` containing `REDIS_PASSWORD` (`k8s/10-redis-secret.yaml`, written with `stringData:` for readability; learning-grade plaintext).
- ✅ Stage 4.3: Created the ConfigMap `redis-config` with `REDIS_HOST=redis` and `REDIS_PORT="6379"` (`k8s/20-redis-configmap.yaml`; port quoted because ConfigMap values must be strings).
- ✅ Stage 4.4: Deployed Redis — ClusterIP Service `redis` + StatefulSet `redis` (1 replica, `redis:7-alpine`, `--requirepass $(REDIS_PASSWORD)` via Kubernetes env-var substitution, `REDISCLI_AUTH` env also set so probes authenticate, `exec` probes running `redis-cli ping`). Auto-provisioned PVC `data-redis-0` (1Gi, RWO) via K3s's `local-path` StorageClass. All in `k8s/30-redis.yaml`.
- ✅ Stage 4.5: Deployed API — ClusterIP Service `counter-api` (port 80 → targetPort 5000) + Deployment `counter-api` (2 replicas of `leodvethings/k3s-counter-api:v1`, `envFrom` the ConfigMap, explicit `env.valueFrom.secretKeyRef` for the Secret, `tcpSocket` probes on 5000, `RollingUpdate` strategy with `maxSurge: 1` / `maxUnavailable: 0`). All in `k8s/40-api.yaml`. Verified from inside the cluster via a throwaway `curlimages/curl` pod: counter increments across requests and responses rotate between the two API pod names, proving Service load-balancing works.
- ✅ Stage 4.6: Created the Traefik Ingress (`k8s/50-ingress.yaml`) — `ingressClassName: traefik`, no host filter, single rule routing path `/` (`pathType: Prefix`) to the `counter-api` Service on port 80. Verified Traefik picked it up: `kubectl get ingress -n counter-app` shows `ADDRESS` populated with all three node public IPs.
- ✅ Stage 4.7: End-to-end browser verification complete. `http://<server_public_ip>/` returns the JSON payload; across multiple refreshes `visit_count` strictly increments (Redis state + atomic INCR working) and the `pod` field rotates between both API pod hostnames (Service load-balancing working). Full chain proven: browser → Azure NSG → Klipper → Traefik → Ingress rule → `counter-api` Service → API pod → Redis.

## Azure Subscription Details

- Subscription ID: `<YOUR_SUBSCRIPTION_ID>`
- Region: `West US 2`
- Core quota: 4 cores (hard limit on this subscription)
- VM size: `Standard_F1als_v7` (1 core, 2 GB RAM). B1-series 1-core SKUs were capacity-restricted in westus2; 2-core SKUs would exceed the 4-core quota (3 × 2 = 6).
- SSH key pair: `~/.ssh/azure_vm_key` (private), `~/.ssh/azure_vm_key.pub` (public)
- SSH user: `azureuser`
- SSH: `ssh -i ~/.ssh/azure_vm_key azureuser@<public-ip>`
- Public IPs are re-assigned on every `terraform apply` — always read current values with `terraform output` from `project_files/`.

## Project Structure

```
ms_azure_make_vm/
├── project_files/                      ← GIT REPO ROOT (Terraform root)
│   ├── main.tf                         ← Root module: providers, shared infra, 3 module calls, outputs
│   ├── .terraform.lock.hcl             ← Provider version lock (committed to git)
│   ├── .gitignore                      ← Excludes .terraform/, *.tfstate, *.tfstate.backup
│   ├── terraform.tfstate               ← Current state
│   ├── terraform.tfstate.backup        ← Previous state
│   ├── .terraform/                     ← Downloaded providers (gitignored)
│   ├── llm_context.md                  ← This file (currently untracked in git)
│   ├── scripts/                        ← Cloud-init templates for Terraform
│   │   ├── install-k3s-server.sh       ← templatefile vars: k3s_token
│   │   └── install-k3s-agent.sh        ← templatefile vars: k3s_token, server_private_ip
│   ├── modules/
│   │   └── vm/
│   │       ├── main.tf                 ← Resources: public IP, NSG, NIC, NIC-NSG association, Linux VM
│   │       ├── variables.tf            ← 9 variables
│   │       └── outputs.tf              ← 3 outputs: public_ip_address, private_ip_address, vm_id
│   ├── app/                            ← Python app (added for bonus task)
│   │   ├── app.py                      ← Flask API, ~25 lines, reads REDIS_HOST/PORT/PASSWORD from env
│   │   ├── requirements.txt            ← flask==3.0.3, redis==5.0.8, gunicorn==23.0.0 (pinned)
│   │   ├── Dockerfile                  ← Single-stage: python:3.12-slim, copies deps then code, runs gunicorn
│   │   └── .dockerignore               ← Excludes __pycache__/, .git/, .venv/, .DS_Store, etc.
│   └── k8s/                            ← Kubernetes manifests (applied in prefix order)
│       ├── 00-namespace.yaml           ← Namespace: counter-app
│       ├── 10-redis-secret.yaml        ← Secret: redis-secret (REDIS_PASSWORD)
│       ├── 20-redis-configmap.yaml     ← ConfigMap: redis-config (REDIS_HOST, REDIS_PORT)
│       ├── 30-redis.yaml               ← Service + StatefulSet + volumeClaimTemplate for Redis
│       ├── 40-api.yaml                 ← Service + Deployment for counter-api
│       └── 50-ingress.yaml             ← Ingress: routes / to counter-api Service via Traefik
└── personal_files(llm_ignore)/         ← Learning docs, outside the repo
    ├── personal_learning.md
    ├── k3s-terraform-cluster-learning-guide.md
    └── 2026-04-30-ingress-session-teaching-brief.md   ← Brief written for a future LLM tutor; covers the Ingress session and the K8s/K3s concepts the user wants to master
```

## Terraform Configuration Details

### Providers

- `hashicorp/azurerm` ~> 3.0 — Azure resource management
- `hashicorp/random` ~> 3.0 — generates the K3s join token

### Root Module (project_files/main.tf)

**Shared resources:**
- `azurerm_resource_group.rg` — name: `k3s-cluster-rg`, location: `West US 2`
- `azurerm_virtual_network.vnet` — name: `k3s-vnet`, address space: `10.0.0.0/16`
- `azurerm_subnet.subnet` — name: `k3s-subnet`, CIDR: `10.0.1.0/24`
- `random_password.k3s_token` — 32-char alphanumeric, no specials

**Module calls:**

| Module label | VM name | extra_open_ports | custom_data script | depends_on |
|---|---|---|---|---|
| `server` | `k3s-server` | `[6443, 80, 443]` | `install-k3s-server.sh` | none |
| `agent1` | `k3s-agent-1` | `[]` | `install-k3s-agent.sh` | `[module.server]` |
| `agent2` | `k3s-agent-2` | `[]` | `install-k3s-agent.sh` | `[module.server]` |

**Outputs:** `server_public_ip`, `server_private_ip`, `agent1_public_ip`, `agent2_public_ip`

### VM Module (modules/vm/)

**Variables (9):**

| Variable | Type | Required | Default | Purpose |
|---|---|---|---|---|
| `vm_name` | string | yes | — | Names all resources |
| `resource_group_name` | string | yes | — | RG to create in |
| `location` | string | yes | — | Azure region |
| `subnet_id` | string | yes | — | Subnet to attach NIC to |
| `subnet_cidr` | string | yes | — | Used in NSG rule for intra-subnet traffic |
| `extra_open_ports` | list(number) | no | `[]` | Ports to open from internet (dynamic block) |
| `vm_size` | string | no | `Standard_F1als_v7` | VM SKU |
| `admin_username` | string | no | `azureuser` | SSH user |
| `ssh_public_key_path` | string | no | `~/.ssh/azure_vm_key.pub` | Public key path |
| `custom_data` | string | no | `null` | Base64-encoded cloud-init script |

**Resources per module call (5):** public IP (Static/Standard), NSG, NIC, NIC-NSG association, Linux VM (Ubuntu 22.04 LTS gen2, SSH key auth only).

**Outputs (3):** `public_ip_address`, `private_ip_address`, `vm_id`.

### NSG Rules Per VM

**Server (`k3s-server-nsg`):** priority 1000 allow intra-subnet; 1001 SSH; 1100 TCP/6443 (K3s API); 1101 TCP/80; 1102 TCP/443.
**Agents:** priority 1000 intra-subnet; 1001 SSH. No extra ports.

## Bonus Task — App Details

### `app/app.py`

Flask app, single endpoint:
- `GET /` → `r.incr("visits")` (atomic), returns JSON `{"message", "visit_count", "pod": socket.gethostname()}`
- Reads `REDIS_HOST`, `REDIS_PORT` (default `6379`), `REDIS_PASSWORD` from env. Required vars use `os.environ[...]` (fail-fast on missing); port has a default via `.get(...)`.
- `__main__` block uses `app.run()` for local dev only; in the container gunicorn runs the app.

### `app/Dockerfile`

```
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
EXPOSE 5000
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "2", "app:app"]
```

Key choices: `python:3.12-slim` (balance of size and compatibility — glibc, unlike alpine), copy requirements before code for layer-cache efficiency, `--no-cache-dir` to keep image smaller, exec-form `CMD` so gunicorn is PID 1 and receives `SIGTERM` cleanly on K8s pod termination.

### Docker Hub Image

- Pushed to: `leodvethings/k3s-counter-api:v1`
- Platform: `linux/amd64` (cross-compiled via `docker buildx --platform linux/amd64 ... --push`, because user's Mac is arm64 / M3 Pro, VMs are amd64)
- Public repo, no auth required for K3s pull.
- Push command used: `docker buildx build --platform linux/amd64 -t leodvethings/k3s-counter-api:v1 --push .` from `project_files/app/`.

### Kubernetes Architecture — Deployed vs Pending

**Deployed (stages 4.1–4.7):**
- **Namespace** `counter-app` — isolates all app resources.
- **Secret** `redis-secret` (type Opaque) — holds `REDIS_PASSWORD` (one key). Written with `stringData:` in the source YAML.
- **ConfigMap** `redis-config` — `REDIS_HOST=redis`, `REDIS_PORT="6379"`.
- **Redis** — **ClusterIP Service** `redis` (port 6379) + **StatefulSet** `redis` (1 replica, image `redis:7-alpine`). Auth via `--requirepass $(REDIS_PASSWORD)` with value from the Secret. Storage via `volumeClaimTemplates` → PVC `data-redis-0` (1Gi RWO) → dynamically-provisioned PV via K3s's `local-path` StorageClass (directory on the pod's node). `exec` probes running `redis-cli ping` (authenticated via `REDISCLI_AUTH` env). Note: the originally-planned *headless* Service was replaced with a regular ClusterIP for simpler client behavior with a single-replica Redis.
- **API** — **ClusterIP Service** `counter-api` (port 80 → targetPort 5000, port name `http`) + **Deployment** `counter-api` (2 replicas, image `leodvethings/k3s-counter-api:v1`). Env populated by `envFrom` (entire `redis-config` ConfigMap) plus explicit `env.valueFrom.secretKeyRef` for `REDIS_PASSWORD`. `tcpSocket` probes on port 5000 (chosen over HTTP GET `/` to avoid probe traffic incrementing the Redis counter). `RollingUpdate` strategy with `maxSurge: 1`, `maxUnavailable: 0` for zero-downtime updates.
- **Ingress** `counter-api` (`k8s/50-ingress.yaml`) — `apiVersion: networking.k8s.io/v1`, `ingressClassName: traefik`, single rule with no host filter, one path entry `/` (`pathType: Prefix`) → backend Service `counter-api` port `80`. Picked up by K3s's bundled Traefik; `ADDRESS` resolves to all three node public IPs (Klipper exposes 80/443 on every node's host network). No TLS, no annotations.

**Entry path (live):** browser → server's public IP:80 → Azure NSG (80 allowed on server only) → Klipper `svclb-traefik-*` pod on the server's host network → Traefik Service → Traefik pod → Ingress rule match → `counter-api` Service → one of the two API pods → Redis Service → Redis pod.

## Kubectl Setup on User's Mac

- `kubectl` is installed (confirmed working, version check reported Client).
- Kubeconfig at `~/.kube/config`, permissions `0600`.
- Fetched from server via `ssh ... "sudo cat /etc/rancher/k3s/k3s.yaml" > ~/.kube/config`, then `sed` to replace `server: https://127.0.0.1:6443` with `server: https://<server_public_ip>:6443`.
- Any existing kubeconfig was backed up to `~/.kube/config.backup-<timestamp>` before overwrite.
- Verified with `kubectl get nodes` — returns three Ready nodes.

## Key Design Decisions

1. **K3s token:** Pre-generated with `random_password`. Avoids SSH-based provisioning or multi-phase apply.
2. **Ordering:** `depends_on` creates server before agents. Agent script's retry loop handles the gap between "VM exists" and "K3s is running."
3. **Networking:** Single subnet. Intra-subnet NSG rule allows all traffic between nodes (covers all K3s ports). Only the server exposes ports to the internet.
4. **Provisioning:** Cloud-init via `custom_data` (not `remote-exec`). Declarative, no SSH during Terraform apply, scripts run as root on first boot.
5. **TLS SAN:** Server script fetches its own public IP from Azure IMDS at runtime and passes it as `--tls-san`. Avoids circular dependency (public IP created inside the module, custom_data passed in). **Known bug — see issue 6 below.**
6. **App config via env vars:** ConfigMap/Secret → container env vars, not baked into the image. 12-factor-style.
7. **Redis inside the cluster:** Not a managed Azure service. Avoids needing extra Azure resources and teaches StatefulSet + PVC.
8. **Docker Hub over ACR:** Public image + zero auth config in K3s.
9. **Pinned image tag (`:v1`, not `:latest`):** Auditable; K8s `imagePullPolicy` defaults to `IfNotPresent` for explicit tags (cached), `Always` for `:latest`.

## Issues Encountered and Resolutions

1. **Core quota exceeded:** Original `Standard_D2als_v7` (2 cores) × 3 = 6 > 4. Switched to `Standard_F1als_v7` (1 core).

2. **SKU capacity restriction:** `Standard_B1ms` listed in region but capacity-restricted. Learned `az vm list-sizes` shows what's defined, `az vm list-skus` shows actual availability. All B1-series 1-core SKUs were restricted in westus2.

3. **VMs stopped after size change:** Terraform changing VM size from D2als to F1als caused Azure to deallocate. Needed manual `az vm start`.

4. **`templatefile` parsing comments:** `${...}` in bash script comments parsed by `templatefile()` as Terraform interpolation. Fixed by removing `${...}` syntax from comments.

5. **SSH key path:** Default `ssh` doesn't know about custom key names. Must use `ssh -i ~/.ssh/azure_vm_key`.

6. **IMDS race in `install-k3s-server.sh` causing missing TLS SAN — FIXED in script, pending destroy/apply verification.** At cloud-init time, the curl to Azure IMDS for the public IP could return empty (public IP attachment race). Script then ran `--tls-san ""` which K3s silently ignored. Cert was issued only for private IP and localhost, so `kubectl` from Mac failed with `x509: certificate is valid for 10.0.1.4, 10.43.0.1, 127.0.0.1, ::1, not <public_ip>`.
   - **Live patch applied on the *currently-running* server (NOT in Terraform):**
     - Wrote `/etc/rancher/k3s/config.yaml` with:
       ```
       tls-san:
         - <server_public_ip>
       ```
     - `sudo rm -f /var/lib/rancher/k3s/server/tls/dynamic-cert.json`
     - `sudo systemctl restart k3s`
   - **Permanent script-level fix applied (2026-04-30):** `scripts/install-k3s-server.sh` now polls IMDS up to 30 times with 2s sleeps and `--max-time 5` per attempt, exiting non-zero if IMDS still returns empty after ~60s. See lines 14–57 of the script.
   - **Status of the live patch:** still in place on the running server, but will be discarded with the VM on the next `terraform destroy`. After `terraform apply` re-creates the cluster, the script's polling loop should produce a correct cert on first boot, eliminating the need to re-apply the live patch.
   - **Verification still pending:** the fix has not yet been exercised by a real destroy + apply cycle. Once that completes successfully and `kubectl get nodes` works from the Mac without any live patch, this issue can be marked fully resolved and the "Live Cluster State Not Captured in Terraform" section below can be deleted.

7. **Docker Hub CLI auth:** Password auth is disabled; `docker login` requires a Personal Access Token (PAT). Generated with Read & Write scope.

8. **Cross-architecture build:** Mac is arm64, VMs are amd64. Native `docker build` produced arm64 images unusable on VMs. Fixed with `docker buildx build --platform linux/amd64 ... --push`. QEMU emulation handled the amd64 build steps.

9. **Heredoc EOF indentation:** In interactive shell on the server, `<<EOF ... EOF` with an indented closing `EOF` caused bash to wait indefinitely. Fixed by using `echo 'line' | sudo tee -a file` for each line instead.

## Live Cluster State Not Captured in Terraform

> **Note (2026-04-30):** the script-level fix in `install-k3s-server.sh` (polling IMDS until it returns a non-empty public IP) has been applied. After the next `terraform destroy` + `terraform apply`, the live patches below should no longer be necessary on the new cluster. This section will be deleted once that cycle is verified.

The *currently-running* server VM has been manually modified beyond what Terraform applied:
- `/etc/rancher/k3s/config.yaml` written with `tls-san` entry.
- `/var/lib/rancher/k3s/server/tls/dynamic-cert.json` deleted (regenerated by K3s on restart).
- K3s restarted to pick up the new SAN.

These patches will be discarded when the VM is destroyed; the new cluster created by re-apply should not need them, because the script now polls IMDS correctly.

## Future Considerations

Improvements identified but deferred — worth revisiting when the bonus task is done:

1. ~~**Fix the IMDS race in `install-k3s-server.sh` (permanent fix for issue #6).**~~ **DONE 2026-04-30.** The script now polls IMDS up to 30 attempts × 2s with `--max-time 5` per attempt and exits non-zero if no public IP is returned after ~60s. Pending real-world verification via the next `terraform destroy` + `terraform apply` cycle.

## How to Operate

All Terraform commands run from `project_files/`:
```
terraform apply     # Create/update
terraform destroy   # Delete
terraform output    # Show IPs
terraform plan      # Preview
```

Verify cluster from Mac:
```
kubectl get nodes
```

Verify cluster from server (if Mac kubectl fails):
```
ssh -i ~/.ssh/azure_vm_key azureuser@<server_public_ip>
sudo kubectl get nodes
```

Cloud-init logs (debugging):
```
sudo cat /var/log/cloud-init-output.log
```

K3s service status:
```
sudo systemctl status k3s --no-pager
```

Rebuild + push image (from `project_files/app/`):
```
docker buildx build --platform linux/amd64 -t leodvethings/k3s-counter-api:<new-tag> --push .
```
