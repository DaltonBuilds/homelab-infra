# Ansible structure

How the inventory, playbooks and roles in `ansible/` fit together.

```mermaid
flowchart LR
  subgraph inv["Inventory: who, and with what values"]
    hosts["hosts.yaml<br/>7 hosts and IPs"]
    gv["group_vars/pve.yaml<br/>shared values"]
    hv["host_vars/pve-0N.yaml<br/>bridge VLANs, unused NICs;<br/>pve-07: GPU IDs, ARC, local-zfs"]
  end

  subgraph pb["Playbooks: what you run"]
    inspect["pve-inspect.yaml<br/>read-only report"]
    baseline["pve-baseline.yaml<br/>converge, one host at a time"]
    verify["pve-verify.yaml<br/>read-only checks"]
    update["pve-update.yaml<br/>upgrade and reboot, one host at a time"]
    netcfg["pve-network.yaml<br/>bridge maintenance, one host at a time"]
    gpucfg["pve-gpu-configure.yaml<br/>pve-07 maintenance"]
    tsr["ts-router.yaml<br/>create container, enroll router"]
    tsrver["ts-router-verify.yaml<br/>read-only checks"]
  end

  subgraph rb["roles/pve_baseline"]
    conv["converge.yaml"]
    pre["preflight.yaml"]
    ident["identity.yaml"]
    apt["apt.yaml"]
    aptinv["apt_inventory.yaml"]
    nag["subscription_reminder.yaml"]
    tz["time.yaml"]
    notif["notifications.yaml"]
    bver["verify.yaml"]
    aptpy[/"files/apt_sources.py"/]
    srctpl[/"templates/proxmox.sources.j2"/]
  end

  subgraph ru["roles/pve_update"]
    upg["upgrade.yaml"]
  end

  subgraph rn["roles/pve_network"]
    nconf["configure.yaml"]
    nver["verify.yaml"]
    nguest["guests.yaml"]
    ntpl[/"templates/interfaces.j2"/]
  end

  subgraph rg["roles/pve_gpu"]
    gconf["configure.yaml"]
    ginsp["inspect.yaml"]
    gpre["preflight.yaml"]
    gver["verify.yaml"]
    gpy[/"files/inspect.py"/]
    gtpl[/"templates/homelab-gpu-vfio.conf.j2"/]
    ghand{{"handlers: rebuild initramfs"}}
  end

  subgraph rt["roles/ts_router"]
    tcont["container.yaml<br/>runs on pve-03"]
    tconf["configure.yaml"]
    tver["verify.yaml"]
  end

  inv -.-> pb

  inspect -->|"pve-07 only"| ginsp
  baseline --> conv
  baseline -->|"after each host"| bver
  verify --> bver
  verify -->|"pve-07 only"| gver
  update --> upg
  update -->|"after each host"| bver
  update -->|"pve-07 only"| gver
  verify --> nver
  netcfg --> nconf
  netcfg -->|"after each host"| nver
  gpucfg --> gconf

  conv --> pre --> ident
  conv --> apt --> aptinv --> aptpy
  apt --> srctpl
  conv --> nag
  conv --> tz
  conv --> notif
  bver --> ident
  bver --> aptinv
  upg -->|"reuses"| pre

  nconf -->|"reuses"| pre
  nconf --> ntpl
  nconf --> nver
  nconf --> nguest
  nver --> ntpl

  tsr --> tcont
  tsr --> tconf
  tsr -->|"after enrollment"| tver
  tsrver --> tver

  gconf --> ginsp --> gpy
  gconf --> gpre
  gconf --> gtpl
  gconf -.->|"notify on change"| ghand
  gver --> ginsp
  gver --> gpre
```

## Reading the diagram

Solid arrows mean "runs". The dashed arrow from the inventory means every playbook reads its variables from there. The dashed arrow to the handler means it runs only when a task reports a change.

- **Inventory** says which hosts exist and holds their values. `group_vars/pve.yaml` applies to every host; `host_vars/<host>.yaml` overrides or adds values for one host. Role `defaults/main.yaml` files hold the lowest-priority values and are not drawn.
- **Playbooks** are what you run. Each one picks a role's entry task file with `tasks_from`.
- **Roles** group the work. Entry task files such as `converge.yaml` pull in smaller task files. Those use the role's `files/` (scripts piped to the host's Python, never installed) and `templates/` (files rendered with inventory values).
- **Shared checks.** `pve_baseline/verify.yaml` is the acceptance check for every host. `pve-verify.yaml` runs it on demand, and `pve-baseline.yaml` and `pve-update.yaml` run it after each host before moving on. `pve_update` and `pve_network` reuse the baseline preflight, so updates and network changes require the same identity and full-quorum checks as configuration changes. `pve_network/verify.yaml` is the network acceptance check; `pve-verify.yaml` and `pve-network.yaml` run it, and it compares the live file with the template so UI edits show up as drift.

Only `pve-baseline.yaml`, `pve-update.yaml`, `pve-network.yaml`, `pve-gpu-configure.yaml` and `ts-router.yaml` change hosts. `ts-router.yaml` creates one container on pve-03 and configures it; it does not change the PVE host's own configuration. The last three also require a confirmation variable for a real run.
