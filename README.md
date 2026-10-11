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
│   ├── requirements.yml             # pinned collections, when added
│   ├── inventories/homelab/         # hosts, group_vars, host_vars
│   ├── playbooks/                   # pve-*, plus ts-router and ts-router-verify
│   └── roles/
│       ├── pve_baseline/            # fleet APT, time, notification checks and verification
│       ├── pve_update/              # gated one-host-at-a-time upgrade and reboot
│       ├── pve_network/             # declared /etc/network/interfaces with automatic rollback
│       ├── pve_gpu/                 # pve-07 GPU inspect, preflight, configure, verify
│       └── ts_router/               # Tailscale subnet router container on pve-03
├── tailscale/policy.hujson          # tailnet policy, applied by GitHub Actions
└── .github/workflows/               # tailscale-policy: test on PR, apply on merge
```

From the repo root, `mise install` installs the pinned Ansible CLI. `mise.toml` points `ANSIBLE_CONFIG` at `ansible/ansible.cfg`. Galaxy collections install under `ansible/collections/`, which Git ignores; the current roles use only `ansible.builtin`. Shared values live in `inventories/homelab/group_vars/pve.yaml`; per-host differences live in `host_vars/`. See [Ansible structure](docs/ansible-structure.md) for a diagram of how the pieces connect.

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

Managed Tailscale (free Personal plan) gives the administrator TCP 8006 and 22 on the seven PVE management addresses from outside the LAN ([HOMELAB-39](https://daltonbuilds.youtrack.cloud/issue/HOMELAB-39)). Placement is decided in [HOMELAB-37](https://daltonbuilds.youtrack.cloud/issue/HOMELAB-37): `ts-router-01`, an unprivileged LXC (guest 110, 1 core, 256 MB, 4 GB) on pve-03 at `192.168.40.13`. Tailscale supplies network access only; Proxmox authentication, Proxmox MFA and SSH keys still apply.

### Policy

`tailscale/policy.hujson` is the entire tailnet policy. It grants `autogroup:owner` (on the Personal plan, only the account that owns the tailnet) 8006 and 22 on the seven hosts, auto-approves exactly those seven `/32` routes from `tag:pve-mgmt-router`, and has no default allow-all rule, so traffic between other tailnet devices is denied. Its `tests` block checks allowed and denied destinations on every save; a failing test rejects the policy.

`.github/workflows/tailscale-policy.yaml` runs `test` on pull requests and `apply` on merge to `main`. It authenticates with GitHub's OIDC token through a Tailscale federated identity, so no Tailscale secret is stored in GitHub. One-time setup:

1. In the Tailscale admin console, create a federated identity for GitHub Actions limited to this repository, with only the `policy_file` scope. Set repository variables `TS_FEDERATED_CLIENT_ID` and `TS_FEDERATED_AUDIENCE`.
2. Paste the policy into the console once (its tests run there), then let the workflow own it. The action refuses to overwrite console edits made since its last apply; resolve those in Git.

### Router

```sh
mise exec -- ansible-playbook ansible/playbooks/ts-router.yaml --check --diff
TS_AUTHKEY=... mise exec -- ansible-playbook ansible/playbooks/ts-router.yaml --diff   # first run only
mise exec -- ansible-playbook ansible/playbooks/ts-router-verify.yaml
```

The first play runs on pve-03. It refuses a guest ID used by anything else and an address that already answers, downloads the Debian 13 template, creates the container with `/dev/net/tun` passed through and the administrator public key for root, installs Python, and adds the container's host key to `~/.ssh/known_hosts`. That key is read over the verified SSH session to pve-03. On later runs it only checks that the container still matches inventory; it never changes or deletes it. Check mode stops after the first play until the container exists. When OpenTofu provisioning arrives, import guest 110 instead of recreating it; this guest is Tier 0 bootstrap infrastructure and must not depend on OpenBao or OpenTofu.

The second play installs Tailscale from its stable repository (`present`, not `latest`), enables IPv4 forwarding inside the container only, and enrolls the router once with tag `tag:pve-mgmt-router`, the seven routes from inventory, SNAT on, Tailscale DNS, route acceptance and Tailscale SSH off. Later runs correct the advertised routes with `tailscale set` without a key. Verification requires a running tagged router serving exactly the approved routes, forwarding on, and 8006/22 reachable on every host from the container.

**Enrollment key.** Generate it in the admin console just before the first run: single-use, pre-approved, tagged `tag:pve-mgmt-router`, shortest expiry. Pass it as `TS_AUTHKEY` in the environment of that run only; tasks that handle it use `no_log`. Do not reuse it.

**Key expiry.** Tagged nodes have node-key expiry disabled by default, so the router does not drop off unattended. Verification prints the expiry so a re-enabled expiry shows up. Workstation and phone clients keep normal expiry and re-authenticate through the identity provider with MFA.

**Revocation and re-enrollment.** Remove the device in the admin console, which stops access immediately. On the router run `tailscale logout`, then rerun the playbook with a new `TS_AUTHKEY`. Revoke a lost client the same way. Test this with a temporary client before relying on it.

**Network path.** With SNAT on, PVE hosts see connections from `192.168.40.13`, so replies return without any UniFi route and PVE logs show the router address, not the tailnet client. PVE host firewalls (if enabled) must allow 8006/22 from `.13`. UniFi needs no port forward and no inbound rule; the router only makes outbound connections. On macOS the Tailscale app accepts subnet routes by default; on Linux clients use `--accept-routes`.

**Failure and fallback.** If pve-03 or the container is down, remote access is down; vault-02 also lives on pve-03 but OpenBao keeps quorum. Manage from the LAN (VLAN 10 workstation to each host's UI/SSH) or the local console, then start the container with `pct start 110` on pve-03 or recreate it from this playbook. A VPN cannot start a powered-off host or repair a broken host network.

## Design references

- [Proxmox baseline](https://github.com/DaltonBuilds/homelab-odyssey/blob/main/docs/build/proxmox-baseline.md)
- [ADR-013](https://github.com/DaltonBuilds/homelab-odyssey/blob/main/docs/build/01-adrs.md)

## Secrets

Credentials stay outside Git. See `.gitignore`.
