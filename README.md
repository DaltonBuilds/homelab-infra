# Homelab Infrastructure

Executable configuration for the homelab. Design docs and decisions stay in [homelab-odyssey](https://github.com/DaltonBuilds/homelab-odyssey). Ticket status is in YouTrack, under [HOMELAB-3](https://daltonbuilds.youtrack.cloud/issue/HOMELAB-3).

Current scope is the Proxmox host baseline ([ADR-013](https://github.com/DaltonBuilds/homelab-odyssey/blob/main/docs/build/01-adrs.md)): inventory, inspect, converge, and verify the seven `homelab-pve` nodes from the administrator workstation. Bootstrap does not depend on OpenBao, VyOS, or Kubernetes.

## Layout

```text
homelab-infra/
├── mise.toml                        # pinned ansible-core, yamllint, pre-commit
├── .yamllint.yaml                   # YAML document-start rule
├── .pre-commit-config.yaml
├── ansible/
│   ├── ansible.cfg
│   ├── requirements.yml             # pinned collections, when added
│   ├── inventories/homelab/         # hosts, group_vars, host_vars
│   ├── playbooks/                   # pve-inspect, pve-verify, pve-gpu-configure; pve-baseline planned
│   └── roles/pve_gpu/               # pve-07 GPU inspect, preflight, configure, verify
```

From the repo root, `mise install` installs the pinned Ansible CLI. `mise.toml` points `ANSIBLE_CONFIG` at `ansible/ansible.cfg`. Galaxy collections install under `ansible/collections/`, which Git ignores. The `pve_gpu` role shares GPU inspection and verification between playbooks.

`mise run lint` checks that every YAML file starts with `---`. Install the same check as a Git hook with `mise exec -- pre-commit install`.

## pve-07 GPU adoption

The hardware IDs and ARC observation in `ansible/inventories/homelab/host_vars/pve-07.yaml` come from HOMELAB-11's verified 2026-09-27 implementation. Inspect the current host before adopting them. The role checks PCI addresses/IDs, IOMMU isolation, ASPEED framebuffer availability and the observed **6647971840-byte ARC cap**; it never changes that cap or kernel arguments. Hardware/console differences stop the play for review.

Read-only inspection includes active drivers, IOMMU group members, VFIO configuration files, boot configuration, loaded modules and ARC state:

```sh
mise exec -- ansible-playbook ansible/playbooks/pve-inspect.yaml --limit pve-07
mise exec -- ansible-playbook ansible/playbooks/pve-verify.yaml --limit pve-07
```

`pve-verify.yaml` currently verifies the GPU-specific portion only; it is not full fleet-baseline acceptance. It checks runtime binding and persistent module/binding/blacklist configuration. Read-only GPU commands run even in check mode. Reports contain host configuration; keep captured output out of Git and review it before sharing.

Review the configuration diff without changing files:

```sh
mise exec -- ansible-playbook ansible/playbooks/pve-gpu-configure.yaml --check --diff
```

After reviewing inspection and diff, save affected files off-host, establish local console access, inspect running guests and confirm cluster quorum/headroom. The dedicated play requires this acknowledgement for an actual change:

```sh
mise exec -- ansible-playbook ansible/playbooks/pve-gpu-configure.yaml --diff -e pve_gpu_maintenance_confirmed=true
```

The play manages the two dedicated `homelab-gpu-vfio.conf` files and preserves unrelated entries in `/etc/initramfs-tools/modules`. An initramfs handler runs only when notified by changes; check mode shows predicted file changes but does not regenerate boot images. Per-file backups are created on change. Inspect other modprobe/modules-load files for conflicting rules during adoption; the role does not erase them.

Reboot separately through one-host maintenance, then rerun verification and check UI/SSH, quorum and ZFS health. A second configuration run should have no changes. If initramfs regeneration fails, do not reboot: fix the error and rerun the play to process the pending marker. The role never unloads/rebinds a live device, reboots, installs NVIDIA drivers or attaches a GPU to a guest. Guest attachment belongs to future OpenTofu provisioning; guest drivers/CUDA validation are separate.

For rollback, restore the current run's backed-up files (or remove dedicated files newly created by that run), restore the complete original initramfs module list, regenerate initramfs successfully and reboot during maintenance. The older HOMELAB-11 rollback script is a point-in-time backup; review intervening changes before using it.

## Design references

- [Proxmox baseline](https://github.com/DaltonBuilds/homelab-odyssey/blob/main/docs/build/proxmox-baseline.md)
- [ADR-013](https://github.com/DaltonBuilds/homelab-odyssey/blob/main/docs/build/01-adrs.md)

## Secrets

Credentials stay outside Git. See `.gitignore`.
