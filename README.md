# Homelab Infrastructure

Executable configuration for the homelab. Design docs and decisions stay in [homelab-odyssey](https://github.com/DaltonBuilds/homelab-odyssey). Ticket status is in YouTrack, under [HOMELAB-3](https://daltonbuilds.youtrack.cloud/issue/HOMELAB-3).

Current scope is the Proxmox host baseline ([ADR-013](https://github.com/DaltonBuilds/homelab-odyssey/blob/main/docs/build/01-adrs.md)): inventory, inspect, converge, and verify the seven `homelab-pve` nodes from the administrator workstation. Bootstrap does not depend on OpenBao, VyOS, or Kubernetes.

## Layout

```text
homelab-infra/
├── ansible/
│   ├── ansible.cfg
│   ├── requirements.yml             # pinned collections, when added
│   ├── inventories/homelab/         # hosts, group_vars, host_vars
│   └── playbooks/                   # pve-inspect, pve-baseline, pve-verify
```

Playbooks run from `ansible/`. Shared roles get added when a task is used by more than one play. OpenTofu is intentionally absent until a guest needs to be created by it.

## Docs

- [Proxmox baseline](https://github.com/DaltonBuilds/homelab-odyssey/blob/main/docs/build/proxmox-baseline.md)
- [ADR-013](https://github.com/DaltonBuilds/homelab-odyssey/blob/main/docs/build/01-adrs.md)

## Secrets

Credentials stay outside Git. See `.gitignore`.
