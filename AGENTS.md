# Agent Instructions for homelab-infra

This repository implements homelab automation. Design and acceptance criteria live in the sibling repo [homelab-odyssey](https://github.com/DaltonBuilds/homelab-odyssey). Execution status lives in YouTrack, starting with [HOMELAB-3](https://daltonbuilds.youtrack.cloud/issue/HOMELAB-3).

## Read before changing hosts

- Baseline spec: `../homelab-odyssey/docs/build/proxmox-baseline.md`
- Decision: ADR-013 in `../homelab-odyssey/docs/build/01-adrs.md`

Current work is the Phase 0.1 Proxmox post-install baseline for the seven `homelab-pve` hosts. Firmware setup, disk selection, and the initial USB install stay manual. OpenTofu is not in this repo yet. When it is added, it provisions guests only. It does not install hypervisors or change cluster membership.

## Ansible

Run playbooks from `ansible/`.

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
