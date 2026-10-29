# Agent Instructions for homelab-infra

This repository implements homelab automation. Design and acceptance criteria live in the sibling repo [homelab-odyssey](https://github.com/DaltonBuilds/homelab-odyssey). Execution status lives in YouTrack, starting with [HOMELAB-3](https://daltonbuilds.youtrack.cloud/issue/HOMELAB-3).

## Read before changing hosts

- Baseline spec: `../homelab-odyssey/docs/build/proxmox-baseline.md`
- Decision: ADR-013 in `../homelab-odyssey/docs/build/01-adrs.md`

Current work is the Phase 0.1 Proxmox post-install baseline for the seven `homelab-pve` hosts. Firmware setup, disk selection, and the initial USB install stay manual. OpenTofu is not in this repo yet. When it is added, it provisions guests only. It does not install hypervisors or change cluster membership. The exceptions are guests that Ansible creates before OpenTofu exists: two Tailscale guests on pve-03, `ts-router-01` (guest 110), the Tier 0 bootstrap router for PVE management, and `ts-exit-01` (guest 111), the exit node for remote work on public Wi-Fi; and the three OpenBao VMs `vault-01`/`vault-02`/`vault-03` (guests 120/121/122 on pve-01/02/03, HOMELAB-21). Import all of them into OpenTofu; do not recreate them. After the vault VMs are imported, delete `roles/vault_vm/tasks/create.yaml` and keep its read-only checks (see the README's OpenBao VMs section).

## Ansible

`ansible-core` 2.21.4 is pinned in `mise.toml`. Install it with `mise install` from the repo root. That config sets `ANSIBLE_CONFIG` to `ansible/ansible.cfg`.

YAML files in this repo start with `---`. `mise run lint` checks that, and the same yamllint rule runs from the pre-commit hook.

Inspect a host before adopting it. Do not reinstall a working host to bring it under Ansible.

A normal baseline run must not:

- upgrade or reboot a host
- change bridges or other network configuration
- repartition disks or change storage layout
- create, join, or leave a cluster, or recreate guests
- rename a clustered host

Preserve quorum, `local-lvm` on the ext4 hosts, `local-zfs` and the ARC/GPU setup on `pve-07`, and the Proxmox subscription reminder. Put upgrades, reboots, network changes, and cluster membership in an explicit maintenance procedure, one host at a time, and stop if quorum or post-change checks fail.

## Secrets

Never commit private keys, passwords, enrollment tokens, vault passwords, or command output that contains them. Supply secrets at execution time. Do not paste them into tickets, commits, or logs.
