# Homelab Infrastructure

Executable configuration for the homelab. Design docs and decisions stay in [homelab-odyssey](https://github.com/DaltonBuilds/homelab-odyssey). Ticket status is in YouTrack, under [HOMELAB-3](https://daltonbuilds.youtrack.cloud/issue/HOMELAB-3).

Current scope is the Proxmox host baseline ([ADR-013](https://github.com/DaltonBuilds/homelab-odyssey/blob/main/docs/build/01-adrs.md)): inventory, inspect, converge, and verify the seven `homelab-pve` nodes from the administrator workstation. Bootstrap does not depend on OpenBao, VyOS, or Kubernetes.

## Layout

```text
homelab-infra/
├── mise.toml                        # pinned ansible-core, yamllint, pre-commit
├── .yamllint.yaml                   # YAML document-start rule
├── .pre-commit-config.yaml
├── docs/ansible-structure.md        # diagram of how playbooks, roles and inventory connect
├── ansible/
│   ├── ansible.cfg
│   ├── requirements.yml             # pinned collections (vyos.vyos, ansible.netcommon)
│   ├── inventories/homelab/         # hosts, group_vars, host_vars
│   ├── playbooks/                   # pve-*, ts-router*, ts-exit-node*, vyos-router*, vault-*
│   └── roles/
│       ├── pve_baseline/            # fleet APT, time, local storage content, notification checks and verification
│       ├── pve_update/              # gated one-host-at-a-time upgrade and reboot
│       ├── pve_network/             # declared /etc/network/interfaces with automatic rollback
│       ├── pve_gpu/                 # pve-07 GPU inspect, preflight, configure, verify
│       ├── ts_router/               # Tailscale subnet router container on pve-03
│       ├── vyos_router/             # VyOS VRRP next hop and BGP on bgp-01/bgp-02
│       ├── vault_vm/                # OpenBao VMs vault-01/02/03: create, check, bootstrap
│       └── vault_baseline/          # OpenBao VM hardening, firewall, pinned package and openbao.hcl
├── tailscale/policy.hujson          # tailnet policy, applied by GitHub Actions
└── .github/workflows/               # tailscale-policy: test on PR, apply on merge
```

From the repo root, `mise install` installs the pinned Ansible CLI. `mise.toml` points `ANSIBLE_CONFIG` at `ansible/ansible.cfg`. Galaxy collections install under `ansible/collections/`, which Git ignores: run `mise exec -- ansible-galaxy collection install -r ansible/requirements.yml`. Only `vyos_router` (vyos.vyos, netcommon) and `vault_baseline` (community.general `ufw` and `timezone`) use them; the other roles use only `ansible.builtin`. Shared values live in `inventories/homelab/group_vars/pve.yaml`; per-host differences live in `host_vars/`. See [Ansible structure](docs/ansible-structure.md) for a diagram of how the pieces connect.

`mise run lint` checks that every YAML file starts with `---`. Install the same check as a Git hook with `mise exec -- pre-commit install`.

Every host must have a verified SSH host key in `~/.ssh/known_hosts`. If a reinstalled host's key changed, compare the fingerprint shown by `ssh-keygen -lf /etc/ssh/ssh_host_ecdsa_key.pub` at its local console before replacing the old entry.

## Fleet baseline

```sh
mise exec -- ansible-playbook ansible/playbooks/pve-inspect.yaml
mise exec -- ansible-playbook ansible/playbooks/pve-verify.yaml
mise exec -- ansible-playbook ansible/playbooks/pve-baseline.yaml --check --diff --limit pve-02
mise exec -- ansible-playbook ansible/playbooks/pve-baseline.yaml --diff --limit pve-02
```

Start with one healthy canary, run it a second time to confirm `changed=0`, then adopt the other hosts. `pve-baseline.yaml` runs one host at a time and stops the whole play at the first failure. Before changing a host it requires the inventory hostname, FQDN, address, gateway and Debian release to match, and the cluster to be quorate with all seven votes. After changing a host it runs the same checks as `pve-verify.yaml`.

A baseline run:

- disables enabled enterprise, Ceph and test APT entries in `.list` or deb822 `.sources` files, keeps Debian and security sources, adds one `pve-no-subscription` entry only if none exists, and runs `apt-get update --error-on=any`. It stops for review if an entry to disable shares a file with other stanzas, more than one no-subscription entry is enabled, a suite is not `trixie`, or signature checking is bypassed;
- removes the post-install helper's `no-nag-script` APT hook and `pve-remove-nag.sh`, which re-patch the UI after every package operation;
- sets the timezone and checks that the notification target exists;
- copies each file to `/root/homelab-baseline-backup/` on the host before its first change.

It never upgrades or reboots a host, changes networking, storage or cluster membership, rewrites root's authorized keys (cluster-shared under `/etc/pve/priv`), or changes SSH daemon or firewall settings. Verification checks APT, identity, quorum, absence of HA resources, cluster services, node-local storage, the management bridge and its physical port, resolver and name resolution, time synchronization, the administrator key fingerprint and pve-07's runtime and persistent ARC cap. It also fails on APT drift: an enabled repository outside the known kinds (allow deliberate ones in `pve_baseline_apt_allowed_other_uris`), or Debian components other than `main contrib non-free-firmware`. It reports firewall status and whether the packaged UI files are still modified. `pve-verify.yaml` also runs the network checks described under [Bridge network](#bridge-network).

Check mode limitations: commands that change state (`apt-get update`, `timedatectl set-timezone`, the test notification) are skipped, backup copies are not simulated, and post-change verification is skipped because predicted changes have not happened. Read-only inspection still runs.

Send a test notification after the target delivers mail. Confirm receipt by hand:

```sh
mise exec -- ansible-playbook ansible/playbooks/pve-baseline.yaml --limit pve-02 -e pve_baseline_notification_test=true
```

### Maintenance procedures

These are deliberately outside a baseline run. Do them one host at a time with local console access, confirm `pvecm status` is quorate with all votes before and after, and stop if a host fails `pve-verify.yaml`.

- **Restore the subscription reminder.** Removing the helper hook stops new patching, but `proxmoxlib.js` stays modified until `proxmox-widget-toolkit` is reinstalled or upgraded. Either upgrade during update maintenance, or reinstall the installed version: `apt-get install --reinstall proxmox-widget-toolkit=$(dpkg-query -W -f='${Version}' proxmox-widget-toolkit)`. Then confirm `dpkg --verify proxmox-widget-toolkit` prints nothing.
- **Updates.** Use `pve-update.yaml`, below. Match a rebuilt node's update level to the surviving members before joining it.
- **Bridge changes.** Change inventory and use `pve-network.yaml`, below. Do not edit networking in the Proxmox UI; `pve-verify.yaml` reports it as drift.
- **Firewall changes.** Keep console access and confirm quorum and `pve-verify.yaml` afterwards.
- **Rollback of a baseline run.** Copy files back from `/root/homelab-baseline-backup/` to their original paths and run `apt-get update`.

### Updates

```sh
mise exec -- ansible-playbook ansible/playbooks/pve-update.yaml --check
mise exec -- ansible-playbook ansible/playbooks/pve-update.yaml -e pve_update_maintenance_confirmed=true
```

`pve-update.yaml` aligns versions by upgrading every host to the latest packages in the same session, one host at a time. For each host it:

1. runs the baseline preflight (identity, quorate cluster with all votes) and requires the maintenance acknowledgement;
2. stops if guests are running, because a reboot shuts them down. Stop or move them, or pass `-e pve_update_allow_running_guests=true` to accept the shutdown. It also stops if a GPU initramfs rebuild is pending;
3. runs `apt-get update --error-on=any` and `apt-get dist-upgrade` without prompts, keeping local configuration files;
4. reboots only if the running kernel is older than the newest installed one or a package requested it, then waits for SSH, `pve-cluster`, `pveproxy` and full quorum;
5. runs `pve-verify.yaml`'s checks, including GPU verification on pve-07, before moving to the next host.

It ends by reporting each host's `pveversion` and whether they all match. Run it across all hosts in one session so they land on the same versions; a `--limit` run updates only those hosts.

Check mode lists the hosts with pending upgrades but decides about rebooting from the kernels installed now; a real run decides after upgrading, so a newly installed kernel also triggers a reboot. A pinned kernel (`proxmox-boot-tool kernel pin`) makes the newest-kernel comparison reboot every run; unpin it or limit those hosts out.

## Bridge network

Inventory declares each host's `/etc/network/interfaces`: `pve_network_*` in `group_vars/pve.yaml` for the fleet, and per host in `host_vars/` the tagged VLANs the switch trunks to it (`pve_network_bridge_vids`) and unused NIC stanzas to keep (`pve_network_manual_nics`). The bridge address is the host's `ansible_host`. Management VLAN 40 stays native/untagged on `vmbr0` ([HOMELAB-40](https://daltonbuilds.youtrack.cloud/issue/HOMELAB-40)).

```sh
mise exec -- ansible-playbook ansible/playbooks/pve-network.yaml --check --diff --limit pve-03
mise exec -- ansible-playbook ansible/playbooks/pve-network.yaml --diff --limit pve-03 -e pve_network_maintenance_confirmed=true
```

Start with a host that has no guests, then the rest, leaving hosts with running guests for last. For each host it:

1. runs the baseline preflight (identity, quorate cluster with all votes), requires the maintenance acknowledgement and refuses to start if an earlier rollback timer is still armed;
2. does nothing else if the file already matches inventory;
3. copies the current file to `/root/homelab-network-backup/`, arms a `homelab-network-rollback` systemd timer (5 minutes), writes the new file and runs `ifreload -a`;
4. waits for SSH and full quorum, checks `ifquery --all --check`, the file, VLAN filtering and the VLANs on the physical port, then disarms the timer;
5. reports guests whose bridge port still carries only untagged traffic.

If a check fails while the host is reachable, the play restores the backup immediately and stops. If the host becomes unreachable, the timer restores the backup and reloads networking on its own. Either way, check the host from its console and confirm quorum before trying again. No host reboot is involved.

Guests that were running when VLAN filtering was turned on keep only VID 1 on their port, because Proxmox assigns VLANs when it plugs a port in. Stop and start each reported guest from Proxmox (`qm shutdown <vmid> && qm start <vmid>`); a reboot from inside the guest keeps the old port. Proxmox gives untagged guest NICs VIDs 2-4094 unless `trunks=` limits them; `pve_network_bridge_vids` only limits what the physical port carries.

To add a VLAN later, for example 70, add it to the host's `pve_network_bridge_vids` after the switch trunks it, then run the playbook for that host.

## pve-07 GPU adoption

The hardware IDs and ARC observation in `ansible/inventories/homelab/host_vars/pve-07.yaml` come from HOMELAB-11's verified 2026-09-27 implementation. Inspect the current host before adopting them. The role checks PCI addresses/IDs, IOMMU isolation, ASPEED framebuffer availability and the observed **6647971840-byte ARC cap**; it never changes that cap or kernel arguments. Hardware/console differences stop the play for review.

Read-only inspection includes active drivers, IOMMU group members, VFIO configuration files, boot configuration, loaded modules and ARC state:

```sh
mise exec -- ansible-playbook ansible/playbooks/pve-inspect.yaml --limit pve-07
mise exec -- ansible-playbook ansible/playbooks/pve-verify.yaml --limit pve-07
```

On GPU hosts, `pve-verify.yaml` also checks runtime binding and persistent module/binding/blacklist configuration. Read-only GPU commands run even in check mode. Reports contain host configuration; keep captured output out of Git and review it before sharing.

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

## Remote management (Tailscale)

Managed Tailscale (free Personal plan) gives the administrator TCP 8006 and 22 on the seven PVE management addresses, and TCP 22 on the two VyOS routers, from outside the LAN ([HOMELAB-39](https://daltonbuilds.youtrack.cloud/issue/HOMELAB-39), [HOMELAB-17](https://daltonbuilds.youtrack.cloud/issue/HOMELAB-17)). Placement is decided in [HOMELAB-37](https://daltonbuilds.youtrack.cloud/issue/HOMELAB-37): `ts-router-01`, an unprivileged LXC (guest 110, 1 core, 256 MB, 4 GB) on pve-03 at `192.168.40.13`. Tailscale supplies network access only; Proxmox authentication, Proxmox MFA and SSH keys still apply.

### Policy

`tailscale/policy.hujson` is the entire tailnet policy. It grants the administrator login 8006 and 22 on the seven hosts and 22 on `bgp-01`/`bgp-02` (`.10`/`.11`), auto-approves exactly those nine `/32` routes from `tag:pve-mgmt-router`, never routes the VRRP VIP `.12`, and has no default allow-all rule, so traffic between other tailnet devices is denied. Its `tests` block checks allowed and denied destinations on every save; a failing test rejects the policy.

The repository is public, so the policy says `ADMIN_LOGIN` where the administrator login belongs. Policy tests need a real login; `autogroup:owner` is rejected in tests.

`.github/workflows/tailscale-policy.yaml` runs `test` on pull requests and `apply` on merge to `main`. It fills in the login from the `TS_ADMIN_LOGIN` repository secret, which GitHub masks in logs, and authenticates with GitHub's OIDC token through a Tailscale federated identity, so no Tailscale credential is stored in GitHub. One-time setup:

1. In the Tailscale admin console, create a federated identity for GitHub Actions with issuer `https://token.actions.githubusercontent.com`, subject `repo:DaltonBuilds@64839972/homelab-infra@1403333457:*` (GitHub subjects include the owner and repository IDs) and only the `policy_file` scope. Set repository variables `TS_FEDERATED_CLIENT_ID` and `TS_FEDERATED_AUDIENCE`, and repository secret `TS_ADMIN_LOGIN`.
2. Paste the policy into the console once with the login filled in (`sed 's|ADMIN_LOGIN|<login>|g' tailscale/policy.hujson | pbcopy`); its tests run there, then let the workflow own it. The action refuses to overwrite console edits made since its last apply; resolve those in Git.

### Router

```sh
mise exec -- ansible-playbook ansible/playbooks/ts-router.yaml --check --diff
TS_AUTHKEY=... mise exec -- ansible-playbook ansible/playbooks/ts-router.yaml --diff   # first run only
mise exec -- ansible-playbook ansible/playbooks/ts-router-verify.yaml
```

The first play runs on pve-03. It refuses a guest ID used by anything else and an address that already answers, downloads the Debian 13 template, creates the container with `/dev/net/tun` passed through and the administrator public key for root, installs Python, and adds the container's host key to `~/.ssh/known_hosts`. That key is read over the verified SSH session to pve-03. On later runs it only checks that the container still matches inventory; it never changes or deletes it. Check mode stops after the first play until the container exists. When OpenTofu provisioning arrives, import guest 110 instead of recreating it; this guest is Tier 0 bootstrap infrastructure and must not depend on OpenBao or OpenTofu.

The second play installs Tailscale from its stable repository (`present`, not `latest`), enables IPv4 forwarding inside the container only, and enrolls the router once with tag `tag:pve-mgmt-router`, the PVE and VyOS routes from inventory, SNAT on, Tailscale DNS, route acceptance and Tailscale SSH off. Later runs correct the advertised routes with `tailscale set` without a key. Verification requires a running tagged router serving exactly the approved routes, forwarding on, 8006/22 reachable on every host and 22 on every VyOS router from the container.

**Adding a route.** Merge the policy change first so the workflow applies the new auto-approval, then run `ts-router.yaml`. In the other order the router advertises a route the policy does not approve, and verification fails until the policy lands.

**Enrollment key.** Generate it in the admin console just before the first run: single-use, pre-approved, tagged `tag:pve-mgmt-router`, shortest expiry. Pass it as `TS_AUTHKEY` in the environment of that run only; tasks that handle it use `no_log`. Do not reuse it.

**Key expiry.** Tagged nodes have node-key expiry disabled by default, so the router does not drop off unattended. Verification prints the expiry so a re-enabled expiry shows up. Workstation and phone clients keep normal expiry and re-authenticate through the identity provider with MFA.

**Revocation and re-enrollment.** Remove the device in the admin console, which stops access immediately. On the router run `tailscale logout`, then rerun the playbook with a new `TS_AUTHKEY`. Revoke a lost client the same way. Test this with a temporary client before relying on it.

**Network path.** With SNAT on, PVE hosts see connections from `192.168.40.13`, so replies return without any UniFi route and PVE logs show the router address, not the tailnet client. PVE host firewalls (if enabled) must allow 8006/22 from `.13`, and the VyOS routers see SSH from `.13` the same way. UniFi needs no port forward and no inbound rule; the router only makes outbound connections. Clients must accept subnet routes: turn on **Use Tailscale subnets** in the macOS app (it was off on the workstation) or run `tailscale set --accept-routes=true`. While accepted, the client sends PVE traffic through the router even on the LAN, so PVE sees `.13` there too, and with the router down the client may black-hole those nine addresses. For LAN or outage management, turn subnet use off or quit Tailscale first. Host names under `homelab.internal` resolve only through UniFi DNS on the LAN, and the policy does not route DNS, so remote clients keep the seven `pve-0N.homelab.internal` names in `/etc/hosts`; this also keeps management independent of lab DNS.

**Failure and fallback.** If pve-03 or the container is down, remote access is down; vault-03 also lives on pve-03 but OpenBao keeps quorum. Manage from the LAN (VLAN 10 workstation to each host's UI/SSH) or the local console, then start the container with `pct start 110` on pve-03 or recreate it from this playbook. A VPN cannot start a powered-off host or repair a broken host network.

### Exit node

`ts-exit-01` (guest 111 on pve-03, `192.168.40.14`) sends a remote client's internet traffic out through home, so public Wi-Fi sees only an encrypted tunnel (HOMELAB-41). It uses the `ts_router` role with no subnet routes and `ts_router_exit_node: true`.

```sh
mise exec -- ansible-playbook ansible/playbooks/ts-exit-node.yaml --check --diff
read -rs "TS_AUTHKEY?Auth key: " && export TS_AUTHKEY && mise exec -- ansible-playbook ansible/playbooks/ts-exit-node.yaml --diff; unset TS_AUTHKEY   # first run only
mise exec -- ansible-playbook ansible/playbooks/ts-exit-node-verify.yaml
```

The policy does not route to the container, so Ansible reaches it through `ProxyJump` via pve-03, from the LAN or remotely. Generate the enrollment key as for the router, tagged `tag:exit-node`. The policy auto-approves exit routes for that tag only and grants the administrator `autogroup:internet`, which excludes private ranges: using the exit node opens nothing on the LAN. The container enables IPv4 and IPv6 forwarding in its own namespace. Verification requires the exit routes to be approved (`Self.AllowedIPs`) and forwarding on.

**Client.** In the macOS menu, choose **Exit Node → ts-exit-01** and keep **Use Tailscale subnets** on for PVE access. Check with `curl -s ifconfig.me` (the home address) and a DNS leak test. If a captive portal reappears, choose **Exit Node → None**, accept it, then reselect, or enable **Allow Local Network Access**.

**Trade-offs and failure.** Traffic is hidden from the local network, not from the home ISP, and sites see the home address. Throughput is capped by home upload. If home internet, pve-03 or the container is down, the client has no internet while the exit node is selected; choose **None** to fall back to the local network. Keep node-key expiry on for clients, and revoke a lost client in the admin console.

## VyOS routers

`bgp-01` (guest 100 on pve-01, `192.168.40.10`) and `bgp-02` (guest 102 on pve-02, `192.168.40.11`) share the VRRP VIP `192.168.40.12` on VLAN 40, the next hop for UniFi's three LoadBalancer `/28` routes ([HOMELAB-17](https://daltonbuilds.youtrack.cloud/issue/HOMELAB-17), [Phase 0.3](https://github.com/DaltonBuilds/homelab-odyssey/blob/main/docs/build/tier-0-foundation.md)). They run iBGP to each other in AS 65000, with the `homelab-prod` (65001) and `homelab-dev` (65002) peer groups staged, empty, for the Tier 2 Cilium speakers. UniFi stays every host's gateway on VLANs 40, 50 and 60; Proxmox hosts never use the VIP.

```sh
mise exec -- ansible-playbook ansible/playbooks/vyos-router.yaml --check --diff --limit bgp-02
mise exec -- ansible-playbook ansible/playbooks/vyos-router.yaml --diff --limit bgp-02
mise exec -- ansible-playbook ansible/playbooks/vyos-router.yaml --diff
mise exec -- ansible-playbook ansible/playbooks/vyos-router-verify.yaml
```

Ansible connects with `network_cli` over paramiko as `vyos`, using the workstation's SSH key and `~/.ssh/known_hosts`; no password is stored. That connection ignores `ProxyJump`, and netcommon 8.7.1 drops `ansible_paramiko_proxy_command`, so remote runs need the Tailscale routes above. Start with bgp-02, the backup, then run both. Each router:

1. must run `vyos_router_version` and carry its inventory address on eth0. Upgrade a router with `add system image` and a reboot, one at a time, before running the play;
2. gets only the configuration lines it is missing (hostname, resolver, default route, VRRP group, BGP, blackhole routes), committed with a comment and saved. Check mode sets them in a session it then discards, so VyOS still rejects invalid syntax. The play never deletes configuration; remove unwanted lines by hand.

Verification checks hostname, VRRP group and priority, the default route via UniFi, the blackhole routes and name resolution. When both routers are in the run it also requires bgp-01 as `MASTER` holding the VIP, bgp-02 as `BACKUP` without it, and iBGP `Established` both ways, retrying for up to 30 seconds after a commit.

**Design changes from Phase 0.3.** UniFi owns `.1` on VLANs 50 and 60, so the design's VLAN50/VLAN60 VRRP groups are omitted, along with the routers' VLAN 50/60 sub-interfaces until Tier 2 decides how speakers peer. The design's `neighbor-group` is `peer-group` in VyOS, and neighbors need `address-family ipv4-unicast`. The resolver is new: without it the default NTP servers never resolve. The `/28` blackholes at distance 254 are new too: until BGP learns those prefixes, traffic UniFi sends to the VIP would otherwise loop between VyOS's default route and UniFi.

**Failover timing.** With the default 1-second advertisements, the backup takes over about 3.6 seconds after the master goes silent (three intervals plus skew). Preemption returns the VIP to bgp-01 when it comes back.

**Rollback.** Each router has a `fresh-install` Proxmox snapshot, and VyOS keeps 100 commit revisions. `show system commit` lists them and `compare <n>` shows a diff in configuration mode; reverse a change with `set`/`delete`, `commit` and `save`. `rollback <n>` also works but reboots the router. Rolling back the snapshot also restores that snapshot's credentials.

## OpenBao VMs

`vault-01`, `vault-02` and `vault-03` (guests 120/121/122 at `192.168.40.20`/`.21`/`.22`) are the three Raft nodes for OpenBao, one per hypervisor: vault-0N runs on pve-0N ([HOMELAB-21](https://daltonbuilds.youtrack.cloud/issue/HOMELAB-21), [ADR-011](https://github.com/DaltonBuilds/homelab-odyssey/blob/main/docs/build/01-adrs.md)). This is Tier 0 bootstrap: nothing here authenticates to OpenBao, so Ansible creates them. OpenTofu imports them at Tier 1.

```sh
mise exec -- ansible-playbook ansible/playbooks/vault-vm.yaml --check --diff --limit vault-03
mise exec -- ansible-playbook ansible/playbooks/vault-vm.yaml --diff --limit vault-03
mise exec -- ansible-playbook ansible/playbooks/vault-vm.yaml --diff
```

One node at a time; vault-01 last, because pve-01 also runs bgp-01. Each run:

1. checks inventory and the cluster (`checks.yaml`, read-only): one node per host, unique guest IDs, no other guest holding the ID or name, and an existing VM matching inventory (name, cores, memory, disk, agent, onboot, cloud-init snippets). It never changes an existing VM;
2. creates a missing VM (`create.yaml`): refuses if the address answers ping, stages the pinned Ubuntu cloud image under `/var/lib/vz/import/` and verifies its SHA256, runs `qm create`, writes the VM's network and vendor snippets to `/var/lib/vz/snippets/`, attaches them with `cicustom`, grows the disk to 20G and boots it. It then waits for the guest agent and for first-boot cloud-init;
3. bootstraps over SSH as `dalton` (`bootstrap.yaml`): checks the OS, hostname and address, installs and starts `qemu-guest-agent`, checks that the agent answers the PVE node, compares the workstation's trusted host key with the key read through the agent, and requires key-only SSH. Only the run that created the VM upgrades and reboots it; add `-e vault_vm_upgrade=true` to repeat that later.

**Why snippets.** Proxmox's generated network config renames the NIC to `eth0`. On Ubuntu 26.04's first boot the dracut initrd has already brought the NIC up as `ens18`, so the rename fails and the VM stays on DHCP. The network snippet matches the NIC by MAC without renaming it. `pve_baseline` enables `snippets` on the cluster-wide `local` storage for this. The initrd still takes a short DHCP lease on every boot before the static address replaces it.

**Host keys.** A new VM's first SSH connection accepts its unseen key (`StrictHostKeyChecking=accept-new` in `group_vars/vault.yaml`). The bootstrap then reads the key through the guest agent, over the already-verified SSH session to the PVE node, and fails if they differ.

**Access.** The tailnet policy does not route `.20`–`.22`, so these VMs are reachable from the LAN only.

**Rebuild.** For a node that holds no data yet: `qm destroy <id> --purge 1` on its PVE node, `ssh-keygen -R <address>` on the workstation, then run the play. After Phase 0.5 a node holds Raft data; rebuild it only through the OpenBao recovery procedure.

### Hardening and OpenBao package

```sh
mise exec -- ansible-playbook ansible/playbooks/vault-baseline.yaml --check --diff --limit vault-03
mise exec -- ansible-playbook ansible/playbooks/vault-baseline.yaml --diff
mise exec -- ansible-playbook ansible/playbooks/vault-verify.yaml
```

`vault-baseline.yaml` runs one node at a time and stops on the first failure ([HOMELAB-26](https://daltonbuilds.youtrack.cloud/issue/HOMELAB-26), [HOMELAB-27](https://daltonbuilds.youtrack.cloud/issue/HOMELAB-27)). On each node it:

1. keeps swap off, now and in `/etc/fstab`;
2. writes `/etc/ssh/sshd_config.d/10-homelab-hardening.conf` (`PermitRootLogin no`, password and keyboard-interactive logins off), checks it with `sshd -t`, and reloads `ssh`;
3. sets `America/Denver` and keeps chrony running;
4. adds the UFW rules before enabling the firewall, so the play's own SSH session stays allowed. The rules: SSH from VLANs 40 and 10; API 8200 from VLANs 40 and 10 only while the listener is plain HTTP (HOMELAB-31; the rules for 50 and 60 are deleted, and Phase 0.7d adds them back); Raft 8201 from `.20`, `.21` and `.22` only, one rule each. Inbound default deny, outbound allow;
5. downloads `openbao_<version>_linux_amd64.deb`, checks it against `vault_baseline_openbao_sha256`, installs it, holds it with `dpkg --set-selections`, and keeps `openbao` stopped and disabled;
6. holds `/opt/openbao/data` at `openbao:openbao 0750` and writes the node's `/etc/openbao/openbao.hcl` (`root:openbao 0640`) from `templates/openbao.hcl.j2` ([HOMELAB-30](https://daltonbuilds.youtrack.cloud/issue/HOMELAB-30)), replacing the package default;
7. with `vault_baseline_openbao_enabled: true`, enables and starts `openbao`. It never restarts a running service: under Shamir a restart seals the node until someone unseals it. If the config changes on a running node, the play reloads it (SIGHUP; no reseal). That applies audit devices and log level live. Listener, storage and seal changes still need a manual restart and unseal, and the play prints a reminder.
8. creates `/opt/openbao/audit` (`openbao:openbao 0750`) and `/etc/logrotate.d/openbao-audit` ([HOMELAB-34](https://daltonbuilds.youtrack.cloud/issue/HOMELAB-34)): daily, 14 kept, `compress` + `delaycompress`, and a `postrotate` that runs `systemctl reload openbao`. The unit's `ExecReload` sends SIGHUP to the main process, which makes the file audit device reopen its log. The file is checked with `logrotate --debug` before it's installed. The device itself is declared in `openbao.hcl` (`audit "file" "file"`). OpenBao rejects `bao audit enable` over the API and applies config-declared devices on the active node at startup or reload.

Then it runs `vault_baseline/tasks/verify.yaml` on that node. That checks: no swap; effective `sshd -T`; timezone and chrony sync with an offset under 300 ms; exactly the seven rules and default policies; the held pinned version and the `openbao` user and group; the config's owner, mode and this node's `node_id`, with no `disable_mlock`, the data directory's owner and mode; and the audit directory's owner and mode plus a clean `logrotate --debug` of the rotation file. Before Phase 0.5 enables it, the service must be disabled and inactive, with nothing on 8200/8201 and `/opt/openbao/data` empty. After that it must be enabled and active and listening on 8200. A sealed node doesn't listen on 8201, so 8201 isn't checked.

`vault-verify.yaml` changes nothing ([HOMELAB-28](https://daltonbuilds.youtrack.cloud/issue/HOMELAB-28)). It runs the `vault_vm` placement, configuration, agent and host-key checks and the baseline verify on all three nodes. It then requires one OpenBao version and one PVE host per node, and prints a per-node summary.

**Phase 0.5 rollout** ([HOMELAB-30](https://daltonbuilds.youtrack.cloud/issue/HOMELAB-30)). First write the config with the service still off, canary first:

```sh
mise exec -- ansible-playbook ansible/playbooks/vault-baseline.yaml --check --diff --limit vault-03
mise exec -- ansible-playbook ansible/playbooks/vault-baseline.yaml --diff --limit vault-03
mise exec -- ansible-playbook ansible/playbooks/vault-baseline.yaml --diff --limit vault-02
mise exec -- ansible-playbook ansible/playbooks/vault-baseline.yaml --diff --limit vault-01
```

Then set `vault_baseline_openbao_enabled: true` in `group_vars/vault.yaml` and run the play again on all three. Start order doesn't matter: nothing is initialized and `retry_join` waits for a leader. Each node comes up sealed and uninitialized. Init (vault-01 only), unseal and `bao audit enable` are manual steps in the build guide. This repo never handles unseal shares or tokens.

**Pinning a new OpenBao release.** Stay within 2.6.x until the seal-plugin migration spike clears 2.7 (ADR-006). Verify the release's `checksums.txt` with its Sigstore bundle, then set `vault_baseline_openbao_version` and `vault_baseline_openbao_sha256` in `group_vars/vault.yaml`:

```sh
gh release download v2.6.5 -R openbao/openbao -p checksums.txt -p checksums.txt.sigstore.json
cosign verify-blob --bundle checksums.txt.sigstore.json \
  --certificate-identity-regexp '^https://github\.com/openbao/openbao/\.github/workflows/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com checksums.txt
grep ' openbao_2.6.5_linux_amd64.deb$' checksums.txt
```

The role releases the hold, installs the new package and holds it again. Upgrading a running cluster is a Phase 0.5+ maintenance procedure, one node at a time; this play does not sequence that.

**What the package does.** Its `postinst` creates the `openbao` system user, a self-signed TLS key and certificate in `/opt/openbao/tls`, and an empty `/opt/openbao/data`. It does not enable or start the service. The certificate is `CN=OpenBao` with no SANs, valid 3 years, so it can't verify the node IPs. The default `openbao.hcl` uses file storage and an HTTPS listener with that certificate; the template replaces it. `postinst` also runs `chown -R openbao:openbao /etc/openbao` on first install, and the role resets the config to `root:openbao 0640`. Checked against the unpacked 2.6.5 `.deb`, 2026-10-29. The unit's capability bounding set is `CAP_SYSLOG` only because OpenBao 2.0 removed mlock (GH-363). 2.6 flags `disable_mlock` as unknown, so the template leaves it out. `MemorySwapMax=0` and the no-swap rule keep secrets off disk. The self-signed pair is unused: the listener is plain HTTP until Phase 0.7d (HOMELAB-31), and init, unseal and root login run against `127.0.0.1` over SSH, never over the network. `vault_baseline_openbao_enabled` stays false until the Phase 0.5 rollout below; until then a run stops a service started by hand.

**Lifecycle.** At Tier 1 [1.3], import the three VMs into OpenTofu state; never recreate them. Then tag the last commit that contains `create.yaml`, delete that file and its include, and replace this section's create step with a pointer to the tag. Only one tool owns the VMs at any time.

## Design references

- [Proxmox baseline](https://github.com/DaltonBuilds/homelab-odyssey/blob/main/docs/build/proxmox-baseline.md)
- [ADR-013](https://github.com/DaltonBuilds/homelab-odyssey/blob/main/docs/build/01-adrs.md)

## Secrets

Credentials stay outside Git. See `.gitignore`.
