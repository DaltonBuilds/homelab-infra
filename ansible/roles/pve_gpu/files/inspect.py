"""Read-only PVE GPU inspection; executed through Python stdin, not installed."""

import json
from pathlib import Path


def read_optional(path):
    path = Path(path)
    return path.read_text().strip() if path.is_file() else None


def pci_device(path):
    group = path / "iommu_group"
    driver = path / "driver"
    return {
        "address": path.name,
        "id": ":".join(read_optional(path / name).removeprefix("0x")
                       for name in ("vendor", "device")),
        "class": read_optional(path / "class"),
        "driver": driver.resolve().name if driver.exists() else None,
        "iommu_group": group.resolve().name if group.exists() else None,
    }


def inspect():
    devices = [pci_device(path) for path in sorted(Path("/sys/bus/pci/devices").glob("*"))
               if read_optional(path / "vendor") == "0x10de"]
    groups = {}
    for device in devices:
        group = device["iommu_group"]
        if group is not None:
            groups[group] = [pci_device(path) for path in sorted(
                Path(f"/sys/kernel/iommu_groups/{group}/devices").glob("*"))]
    files = [
        "/etc/modprobe.d/homelab-gpu-vfio.conf",
        "/etc/modules-load.d/homelab-gpu-vfio.conf",
        "/etc/initramfs-tools/modules",
        "/etc/kernel/cmdline",
        "/etc/default/grub",
    ]
    return {
        "devices": devices,
        "iommu_groups": groups,
        "files": {path: read_optional(path) for path in files},
        "kernel_cmdline": read_optional("/proc/cmdline"),
        "loaded_modules": [line.split()[0] for line in Path("/proc/modules").read_text().splitlines()],
        "framebuffers": {path.name: read_optional(path / "name")
                         for path in sorted(Path("/sys/class/graphics").glob("fb[0-9]*"))},
        "zfs_arc_max": read_optional("/sys/module/zfs/parameters/zfs_arc_max"),
    }


if __name__ == "__main__":
    print(json.dumps(inspect()))
