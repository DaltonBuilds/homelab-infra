"""Read-only APT source inventory; executed through Python stdin, not installed."""

import json
from pathlib import Path

SOURCE_DIR = Path("/etc/apt/sources.list.d")
DISABLED_VALUES = {"no", "false", "0"}


def classify(uris, suites, components):
    text = " ".join(uris)
    if "enterprise.proxmox.com" in text:
        return "enterprise"
    if "/ceph" in text:
        return "ceph"
    if "pve-test" in components:
        return "pve-test"
    if "pve-no-subscription" in components:
        return "pve-no-subscription"
    if "security.debian.org" in text or any(s.endswith("-security") for s in suites):
        return "debian-security"
    if "deb.debian.org" in text:
        return "debian"
    return "other"


def deb822_stanzas(path):
    stanzas, current, key = [], {}, None
    for line in path.read_text().splitlines() + [""]:
        if line.startswith("#"):
            continue
        if not line.strip():
            if current:
                stanzas.append(current)
            current, key = {}, None
        elif line[0].isspace() and key:
            current[key] += " " + line.strip()
        elif ":" in line:
            key, value = line.split(":", 1)
            key = key.strip().lower()
            current[key] = value.strip()
    return stanzas


def sources_entries(path):
    stanzas = deb822_stanzas(path)
    for index, stanza in enumerate(stanzas):
        uris = stanza.get("uris", "").split()
        suites = stanza.get("suites", "").split()
        components = stanza.get("components", "").split()
        yield {
            "path": str(path),
            "format": "deb822",
            "stanza": index,
            "stanzas_in_file": len(stanzas),
            "uris": uris,
            "suites": suites,
            "components": components,
            "signed_by": stanza.get("signed-by"),
            "trusted": stanza.get("trusted", "no").lower() in ("yes", "true"),
            "enabled": stanza.get("enabled", "yes").lower() not in DISABLED_VALUES,
            "kind": classify(uris, suites, components),
        }


def list_entries(path):
    for line in path.read_text().splitlines():
        words = line.split()
        if not words or words[0] not in ("deb", "deb-src"):
            continue
        if len(words) > 1 and words[1].startswith("["):
            while not words[1].endswith("]"):
                words[1:3] = [words[1] + " " + words[2]]
            options, words = words[1], [words[0]] + words[2:]
        else:
            options = ""
        uris, suites, components = words[1:2], words[2:3], words[3:]
        yield {
            "path": str(path),
            "format": "list",
            "line": line,
            "uris": uris,
            "suites": suites,
            "components": components,
            "signed_by": options or None,
            "trusted": "trusted=yes" in options,
            "enabled": True,
            "kind": classify(uris, suites, components),
        }


def inspect():
    entries = []
    legacy = Path("/etc/apt/sources.list")
    paths = ([legacy] if legacy.is_file() else []) + sorted(SOURCE_DIR.glob("*.list"))
    for path in paths:
        entries.extend(list_entries(path))
    for path in sorted(SOURCE_DIR.glob("*.sources")):
        entries.extend(sources_entries(path))
    return {"entries": entries}


if __name__ == "__main__":
    print(json.dumps(inspect()))
