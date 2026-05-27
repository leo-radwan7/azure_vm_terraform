# Current Working Tasks

Feedback from code review. Check off each item as it's completed.

---

- [ ] **1. Move state to a remote backend**
  - Single laptop = single point of failure; K3s token sits in state as plaintext.
  - Target: Azure Storage Account with state locking (blob lease).

- [ ] **2. Collapse two agent module blocks into one with `for_each`**
  - `agent1` and `agent2` are copy-paste identical except for the name.
  - Use `for_each` on the module block to define agents once.

- [ ] **3. Automate kubeconfig retrieval**
  - Currently requires manual SSH + sed to get `kubectl` working from the laptop.
  - Either a Terraform output, `local-exec` provisioner, or a helper script.

- [x] **4. Remove redundant `depends_on` on agent modules**
  - `module.server.private_ip_address` in the templatefile call already creates an implicit dependency.
  - The explicit `depends_on` is unnecessary and forces broader re-planning.

- [ ] **5. Restrict SSH to a specific IP**
  - Port 22 is open to `0.0.0.0/0` on all three VMs.
  - Add an `allowed_ssh_cidr` variable and use it in the NSG rule's `source_address_prefix`.

- [ ] **6. Protect `random_password` from silent token rotation**
  - If the resource is replaced, the new token won't match what's running on existing VMs.
  - Consider `lifecycle { prevent_destroy = true }` or `ignore_changes` on `custom_data`.

- [ ] **7. Document (or automate) the Redis secret**
  - The password is committed as plaintext in `10-redis-secret.yaml`.
  - At minimum document the manual step; production answer is SealedSecrets or Key Vault CSI.

- [ ] **8. Add a README**
  - Clone, apply, verify (`kubectl get nodes`) should be readable in ~30 lines.
  - Subset of what's already in `llm_context.md`, aimed at humans.

- [x] **9. Follow Terraform Standard Module Structure in the root module**
  - Root `main.tf` has providers, resources, locals, and outputs in one file.
  - Split into `main.tf`, `variables.tf`, `outputs.tf` (and optionally `providers.tf`, `locals.tf`).

- [x] **10. Run `tflint`**
  - Install: `brew install tflint`.
  - The `terraform_standard_module_structure` rule will flag #9 plus naming/version-pinning issues.
