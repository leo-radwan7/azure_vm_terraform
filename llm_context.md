# LLM Context: K3s Cluster on Azure with Terraform + Counter App Bonus

## Project Goal

Turn a single-VM Terraform config into a reusable module, use it to stand up three Azure VMs (1 server, 2 agents), provision them as a working K3s Kubernetes cluster via cloud-init scripts, and deploy a small containerized web app to that cluster as a learning exercise.

## Current Status

**Infrastructure (Terraform):**
- Terraform config is complete and currently applied.
- All three VMs created, K3s installed via cloud-init, cluster verified working.
- `kubectl get nodes` returns three Ready nodes running K3s v1.35.5+k3s1.
- Server VM upgraded to `Standard_F2als_v7` (2 cores, 4 GB RAM) to accommodate ArgoCD. Agents remain at `Standard_F1als_v7` (1 core, 2 GB RAM). Total: 4 cores (quota limit).
- **Code-review hardening (2026-05-28):** remote `azurerm` state backend (state off the laptop, locking via blob lease); two agent module blocks collapsed into one `for_each` module; redundant `depends_on` removed (relies on implicit dependency); SSH restricted to `allowed_ssh_cidr`; `random_password` token guarded with `lifecycle { ignore_changes }`; root module split into `main.tf`/`providers.tf`/`variables.tf`/`outputs.tf`; `required_version` added (flagged by tflint). Still pending: Redis-secret documentation (#7) and a README (#8).

**Bonus task (deploy an app reachable from a browser):** ✅ complete.

**ArgoCD (GitOps):** ✅ complete.
- ArgoCD installed via cloud-init on the server VM after K3s is fully stable.
- ArgoCD Application `counter-app` points at `k8s/` directory in GitHub repo (`https://github.com/leo-radwan7/azure_vm_terraform.git`).
- Auto-sync enabled (prune + selfHeal) — changes pushed to `k8s/` in git are automatically applied to the cluster within 3 minutes.
- Dashboard accessible at `http://<server_public_ip>:30443` (HTTP, insecure mode; login: `admin` + auto-generated password from `argocd-initial-admin-secret`).
- GitOps loop verified: changed API replicas from 2 → 3 in git, ArgoCD detected and applied the change automatically.
- Full stack deploys from a single `terraform apply` — no manual `kubectl` needed.
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
- VM sizes: Server `Standard_F2als_v7` (2 cores, 4 GB RAM); agents `Standard_F1als_v7` (1 core, 2 GB RAM). Server was upgraded from F1als to F2als to accommodate ArgoCD's resource requirements. Total: 2+1+1 = 4 cores (quota limit).
- SSH key pair: `~/.ssh/azure_vm_key` (private), `~/.ssh/azure_vm_key.pub` (public)
- SSH user: `azureuser`
- SSH: `ssh -i ~/.ssh/azure_vm_key azureuser@<public-ip>`
- Public IPs are re-assigned on every `terraform apply` — always read current values with `terraform output` from `project_files/`.

## Project Structure

```
ms_azure_make_vm/
├── project_files/                      ← GIT REPO ROOT (Terraform root)
│   ├── main.tf                         ← Root module: shared infra + server module + agent for_each module call
│   ├── providers.tf                    ← terraform block (azurerm remote backend, required_version, required_providers) + provider config
│   ├── variables.tf                    ← Root input variables (allowed_ssh_cidr)
│   ├── outputs.tf                      ← Root outputs (server/agent IPs)
│   ├── terraform.tfvars                ← Variable values incl. allowed_ssh_cidr (gitignored)
│   ├── get-kubeconfig.sh               ← Fetches kubeconfig from server, rewrites API address to public IP
│   ├── .terraform.lock.hcl             ← Provider version lock (committed to git)
│   ├── .gitignore                      ← Excludes .terraform/, *.tfstate*, kubeconfig, *.tfvars
│   ├── .terraform/                     ← Downloaded providers (gitignored)
│   ├── llm_context.md                  ← This file (tracked in git, subscription ID redacted)
│   ├── current_working_tasks.md        ← Code-review task checklist (items 1–10)
│   ├── learning_from_issues_2026-05-28.md ← Study guide explaining the 10 code-review issues
│   ├── issues_encountered_2026-05-26.md ← Detailed issue report from ArgoCD integration sessions
│   ├── scripts/                        ← Cloud-init templates for Terraform
│   │   ├── install-k3s-server.sh       ← templatefile vars: k3s_token; installs K3s + ArgoCD + deploys app via GitOps
│   │   └── install-k3s-agent.sh        ← templatefile vars: k3s_token, server_private_ip
│   ├── modules/
│   │   └── vm/
│   │       ├── main.tf                 ← Resources: public IP, NSG, NIC, NIC-NSG association, Linux VM
│   │       ├── variables.tf            ← 11 variables
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
│       ├── 40-api.yaml                 ← Service + Deployment for counter-api (3 replicas)
│       └── 50-ingress.yaml             ← Ingress: routes / to counter-api Service via Traefik
│   └── argocd/                         ← ArgoCD configuration (separate from k8s/ to avoid self-management loop)
│       └── counter-app.yaml            ← ArgoCD Application: watches k8s/ in GitHub, auto-syncs to cluster
└── personal_files(llm_ignore)/         ← Learning docs, outside the repo
    ├── personal_learning.md
    ├── k3s-terraform-cluster-learning-guide.md
    └── 2026-04-30-ingress-session-teaching-brief.md   ← Brief written for a future LLM tutor; covers the Ingress session and the K8s/K3s concepts the user wants to master
```

## Terraform Configuration Details

### Providers

- `hashicorp/azurerm` ~> 3.0 — Azure resource management
- `hashicorp/random` ~> 3.0 — generates the K3s join token

### Terraform Block & Remote Backend (project_files/providers.tf)

- `required_version = ">= 1.0"` pins the Terraform CLI (added after a `tflint` run flagged its absence).
- **Remote state backend (`azurerm`):** state lives in Azure Blob Storage, not on the laptop.
  - Storage account `tfstatek3sleo`, container `tfstate`, blob key `k3s-cluster.tfstate`, in resource group `terraform-state-rg`.
  - That resource group + storage account were created out-of-band (Azure CLI) and live **outside** this config, so `terraform destroy` can never delete the state it depends on.
  - State locking is native (Azure blob lease) — no separate lock table needed.
  - Auth uses your `az login` credentials to fetch the storage key. After cloning, run `terraform init` to wire up the backend before any plan/apply.

### Root Module (project_files/main.tf)

**Shared resources:**
- `azurerm_resource_group.rg` — name: `k3s-cluster-rg`, location: `West US 2`
- `azurerm_virtual_network.vnet` — name: `k3s-vnet`, address space: `10.0.0.0/16`
- `azurerm_subnet.subnet` — name: `k3s-subnet`, CIDR: `10.0.1.0/24`
- `random_password.k3s_token` — 32-char alphanumeric, no specials. Carries `lifecycle { ignore_changes = [length, special] }` so editing those inputs can't silently regenerate the token — a regenerated token would change every VM's immutable `custom_data` and force a full cluster rebuild.

**Module calls:**

| Module label | VM name(s) | extra_open_ports | custom_data script | ordering |
|---|---|---|---|---|
| `server` | `k3s-server` | `[6443, 80, 443, 30443]` | `install-k3s-server.sh` | none |
| `agent` (`for_each`) | `k3s-agent-1`, `k3s-agent-2` | `[]` | `install-k3s-agent.sh` | implicit (via `module.server.private_ip_address` in custom_data) |

The two agents are now a single `module "agent"` block using `for_each = toset(["k3s-agent-1", "k3s-agent-2"])` (previously duplicate `agent1`/`agent2` blocks). The explicit `depends_on = [module.server]` was removed: the agent `custom_data` references `module.server.private_ip_address`, which already creates an implicit dependency that orders the server before the agents.

**Outputs:** `server_public_ip`, `server_private_ip`, `agent1_public_ip`, `agent2_public_ip` (the agent outputs index the `for_each` instances, e.g. `module.agent["k3s-agent-1"].public_ip_address`)

### VM Module (modules/vm/)

**Variables (11):**

| Variable | Type | Required | Default | Purpose |
|---|---|---|---|---|
| `vm_name` | string | yes | — | Names all resources |
| `resource_group_name` | string | yes | — | RG to create in |
| `location` | string | yes | — | Azure region |
| `subnet_id` | string | yes | — | Subnet to attach NIC to |
| `subnet_cidr` | string | yes | — | Used in NSG rule for intra-subnet traffic |
| `allowed_ssh_cidr` | string | yes | — | CIDR allowed to SSH (port 22); set in terraform.tfvars |
| `extra_open_ports` | list(number) | no | `[]` | Ports to open from internet (dynamic block) |
| `vm_size` | string | no | `Standard_F1als_v7` | VM SKU |
| `admin_username` | string | no | `azureuser` | SSH user |
| `ssh_public_key_path` | string | no | `~/.ssh/azure_vm_key.pub` | Public key path |
| `custom_data` | string | no | `null` | Base64-encoded cloud-init script |

**Resources per module call (5):** public IP (Static/Standard), NSG, NIC, NIC-NSG association, Linux VM (Ubuntu 22.04 LTS gen2, SSH key auth only).

**Outputs (3):** `public_ip_address`, `private_ip_address`, `vm_id`.

### NSG Rules Per VM

**Server (`k3s-server-nsg`):** priority 1000 allow intra-subnet; 1001 SSH (restricted to `var.allowed_ssh_cidr`); 1100 TCP/6443 (K3s API); 1101 TCP/80; 1102 TCP/443; 1103 TCP/30443 (ArgoCD dashboard).
**Agents:** priority 1000 intra-subnet; 1001 SSH (restricted to `var.allowed_ssh_cidr`). No extra ports.

SSH (port 22) is no longer open to the internet. Rule (a) uses `source_address_prefix = var.allowed_ssh_cidr`, threaded from the root module. The value lives in `terraform.tfvars` (gitignored), e.g. `allowed_ssh_cidr = "76.33.188.174/32"`.

⚠️ **SSH lockout gotcha:** Your home/public IP is dynamic — if your ISP changes it, or if you run Terraform / SSH from a different network (coffee shop, office, VPN), the NSG no longer matches your current source IP and **all SSH attempts to every VM will hang/time out**. This is not a key or server problem — it's the firewall silently dropping you. Fix: run `curl -4 ifconfig.me` to get your current IPv4 address, update `allowed_ssh_cidr` in `terraform.tfvars`, then `terraform apply` (only the NSG rules change — no VM rebuild). Note also: only IPv4 is allowed; `curl ifconfig.me` may return an IPv6 address, so always use `-4`. The K3s API (6443), web app (80/443), and ArgoCD dashboard (30443) are unaffected — they remain open to the internet.

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
- **API** — **ClusterIP Service** `counter-api` (port 80 → targetPort 5000, port name `http`) + **Deployment** `counter-api` (3 replicas, image `leodvethings/k3s-counter-api:v1`). Env populated by `envFrom` (entire `redis-config` ConfigMap) plus explicit `env.valueFrom.secretKeyRef` for `REDIS_PASSWORD`. `tcpSocket` probes on port 5000 (chosen over HTTP GET `/` to avoid probe traffic incrementing the Redis counter). `RollingUpdate` strategy with `maxSurge: 1`, `maxUnavailable: 0` for zero-downtime updates.
- **Ingress** `counter-api` (`k8s/50-ingress.yaml`) — `apiVersion: networking.k8s.io/v1`, `ingressClassName: traefik`, single rule with no host filter, one path entry `/` (`pathType: Prefix`) → backend Service `counter-api` port `80`. Picked up by K3s's bundled Traefik; `ADDRESS` resolves to all three node public IPs (Klipper exposes 80/443 on every node's host network). No TLS, no annotations.

**ArgoCD (deployed via cloud-init, manages the app above):**
- **ArgoCD** installed in `argocd` namespace via cloud-init after K3s system pods are fully stable. Uses `--server-side=true` for install to avoid CRD annotation size limits.
- **ArgoCD Application** `counter-app` (`argocd/counter-app.yaml`) — `project: default`, source `k8s/` directory from GitHub repo, destination `https://kubernetes.default.svc` namespace `counter-app`. Auto-sync with `prune: true` and `selfHeal: true`. `CreateNamespace=true` sync option.
- **Dashboard** exposed via NodePort 30443 on the server. ArgoCD runs in insecure mode (plain HTTP, `server.insecure: "true"` in `argocd-cmd-params-cm`). The `argocd-server-network-policy` is deleted by cloud-init to allow external NodePort traffic. Service patched to `port: 80 → targetPort: 8080 → nodePort: 30443`.
- **Login:** username `admin`, password auto-generated in Secret `argocd-initial-admin-secret`.

**Entry path — counter app (live):** browser → server's public IP:80 → Azure NSG (80 allowed on server only) → Klipper `svclb-traefik-*` pod on the server's host network → Traefik Service → Traefik pod → Ingress rule match → `counter-api` Service → one of the three API pods → Redis Service → Redis pod.

**Entry path — ArgoCD dashboard:** browser → server's public IP:30443 → Azure NSG (30443 allowed on server only) → NodePort → `argocd-server` pod (port 8080).

## Kubectl Setup on User's Mac

- `kubectl` is installed (confirmed working, version check reported Client).
- **Automated via `get-kubeconfig.sh`** (in `project_files/`). After `terraform apply`, run:
  ```
  ./get-kubeconfig.sh
  export KUBECONFIG=$PWD/kubeconfig
  kubectl get nodes
  ```
- The script reads `server_public_ip` from `terraform output`, SSHes to the server, reads `/etc/rancher/k3s/k3s.yaml`, rewrites the API address `https://127.0.0.1:6443` → `https://<server_public_ip>:6443`, and writes `./kubeconfig` (0600). It writes a project-local `./kubeconfig` rather than `~/.kube/config`, so it never clobbers other clusters. The file holds cluster admin credentials and is gitignored.
- Re-run the script whenever the server's public IP changes (it's reassigned on every `terraform apply`).
- Verified end-to-end: returns three Ready nodes (`k3s-server`, `k3s-agent-1`, `k3s-agent-2`).

## Key Design Decisions

1. **K3s token:** Pre-generated with `random_password`. Avoids SSH-based provisioning or multi-phase apply. Guarded with `lifecycle { ignore_changes = [length, special] }` so it can't silently regenerate and force a full cluster rebuild.
2. **Ordering:** The agent `custom_data` references `module.server.private_ip_address`, creating an implicit dependency that builds the server before the agents (no explicit `depends_on` needed). The agent script's retry loop handles the gap between "VM exists" and "K3s is running."
3. **Networking:** Single subnet. Intra-subnet NSG rule allows all traffic between nodes (covers all K3s ports). Only the server exposes ports to the internet.
4. **Provisioning:** Cloud-init via `custom_data` (not `remote-exec`). Declarative, no SSH during Terraform apply, scripts run as root on first boot.
5. **TLS SAN:** Server script fetches its own public IP at runtime and passes it as `--tls-san`. Tries Azure IMDS first (15 attempts), falls back to `ifconfig.me` (external IP-lookup service). IMDS is unreliable for Standard SKU public IPs; the fallback is reliable because the VM has internet access. Avoids circular dependency (public IP created inside the module, custom_data passed in).
10. **ArgoCD for GitOps:** Installed via cloud-init after K3s system pods are fully stable. App manifests in `k8s/` are managed by ArgoCD watching the GitHub repo, not by manual `kubectl apply`. Changes pushed to git are automatically applied within 3 minutes.
11. **ArgoCD Application in separate directory:** `argocd/counter-app.yaml` lives outside `k8s/` to avoid ArgoCD trying to manage the Application resource that defines the very directory it watches.
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

6. **IMDS public IP lookup — RESOLVED.** Azure IMDS does not reliably report public IPs for Standard SKU public IPs. The original single-curl approach often returned empty. The script now tries IMDS (15 attempts, ~30s) then falls back to `ifconfig.me` (external IP-lookup service). Verified working across multiple destroy/apply cycles — the fallback consistently provides the correct public IP, and the K3s TLS cert includes it in the SANs. No manual live patching needed.

10. **ArgoCD CRD annotation too long (256KB limit).** `kubectl apply` stores the full resource spec as an annotation. ArgoCD's ApplicationSet CRD exceeds the 256KB limit. Fixed with `--server-side=true` which uses managed fields instead of annotations.

11. **ArgoCD server rollout timeout — VM too small.** `Standard_F1als_v7` (1 core, 2 GB) couldn't handle K3s control plane + ArgoCD (7 pods). Server upgraded to `Standard_F2als_v7` (2 cores, 4 GB). Rollout timeout increased to 300s.

12. **ArgoCD Application missing `spec.project`.** Every Application must belong to an ArgoCD Project. Added `project: default` (the built-in unrestricted project).

13. **ArgoCD dashboard unreachable — three stacked issues.** (a) `argocd-server-network-policy` blocked external NodePort traffic — deleted by cloud-init. (b) Service targetPort defaulted to 443 instead of 8080 (what argocd-server listens on) — patched to correct port. (c) ArgoCD's HTTP→HTTPS redirect created a loop because HTTPS wasn't configured — set `server.insecure: "true"` in `argocd-cmd-params-cm` ConfigMap.

14. **K3s crash loop after ArgoCD install.** Installing ArgoCD immediately after K3s API responds overwhelmed the API server (CRDs + 7 pods before internal controllers stabilized). K3s's cloud-controller-manager couldn't read a configmap, triggering deliberate shutdown → restart loop. Fixed by adding Phase 2 readiness check: wait for all `kube-system` pods to be Running before installing ArgoCD. Verified with clean destroy/apply cycle.

7. **Docker Hub CLI auth:** Password auth is disabled; `docker login` requires a Personal Access Token (PAT). Generated with Read & Write scope.

8. **Cross-architecture build:** Mac is arm64, VMs are amd64. Native `docker build` produced arm64 images unusable on VMs. Fixed with `docker buildx build --platform linux/amd64 ... --push`. QEMU emulation handled the amd64 build steps.

9. **Heredoc EOF indentation:** In interactive shell on the server, `<<EOF ... EOF` with an indented closing `EOF` caused bash to wait indefinitely. Fixed by using `echo 'line' | sudo tee -a file` for each line instead.

15. **SSH lockout after IP change / network change (POTENTIAL — by design).** Since SSH is now restricted to `var.allowed_ssh_cidr` (set in `terraform.tfvars`), SSH to *any* VM will silently hang/time out if your current public IP no longer matches that CIDR — e.g. ISP rotated your dynamic IP, or you're on a different network (office, café, VPN). Symptom looks like a dead server, but it's the Azure NSG dropping the connection. Fix: `curl -4 ifconfig.me` → update `allowed_ssh_cidr` in `terraform.tfvars` → `terraform apply` (only NSG rules change, no VM rebuild). Use `-4` because `ifconfig.me` may return an IPv6 address, but the VMs only have IPv4 public IPs so only an IPv4 `/32` will match. See the NSG Rules Per VM section for details.

## Live Cluster State Not Captured in Terraform

None. As of 2026-05-26, a clean `terraform destroy` + `terraform apply` cycle produces a fully working cluster with ArgoCD deploying the app from git. No manual patches are needed.

## Future Considerations

1. ~~**Fix the IMDS race in `install-k3s-server.sh`.**~~ **DONE and VERIFIED.** Script uses IMDS with ifconfig.me fallback. Confirmed working across multiple destroy/apply cycles.
2. **ArgoCD dashboard security.** Currently plain HTTP with admin password only. In production: Traefik Ingress with TLS (cert-manager + Let's Encrypt), ArgoCD RBAC + SSO via Dex.
3. **Redis secret in git.** Plaintext password committed to git (acceptable for learning). In production: SealedSecrets or External Secrets Operator (Azure Key Vault integration).
4. **Private repo support.** Repo was made public for ArgoCD. For private repos: fine-grained GitHub PAT → Kubernetes Secret with `argocd.argoproj.io/secret-type: repository` label in the `argocd` namespace.
5. **Cloud-init script complexity.** The server script is ~200 lines with 4 major steps. Consider Ansible for post-boot configuration if it grows further — Ansible is re-runnable on existing VMs without destroying them.
6. **K3s version pinning.** Currently installs latest stable. Pin with `INSTALL_K3S_VERSION="v1.35.5+k3s1"` for reproducibility.
7. **ArgoCD sync polling interval.** Default 3 minutes. Can be reduced via `argocd-cm` ConfigMap for faster feedback, or use GitHub webhooks for immediate sync.

## How to Operate

All Terraform commands run from `project_files/`:
```
terraform init      # First run / after clone — connects to the Azure remote state backend
terraform apply     # Create/update
terraform destroy   # Delete
terraform output    # Show IPs
terraform plan      # Preview
```

Fetch kubeconfig + verify cluster from Mac (after apply):
```
./get-kubeconfig.sh
export KUBECONFIG=$PWD/kubeconfig
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

ArgoCD dashboard:
```
http://<server_public_ip>:30443
```
Username: `admin`
Password:
```
sudo kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo
```

ArgoCD Application status:
```
sudo kubectl get applications -n argocd
```
