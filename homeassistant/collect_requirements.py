#!/usr/bin/env python3
"""Prints pip requirements for the integrations that a given Home Assistant version sets up on its own.

  collect_requirements.py 2026.11.1 default_config mqtt zha

Covers: integrations from that version's bootstrap.py (*_INTEGRATIONS: what HA always starts),
the domains given (default_config by default) and everything they depend on, both dependencies
and after_dependencies (modules often import code from after-dependencies, e.g. usb -> hassio).
Manifests come from github.com/home-assistant/core at the version tag. The official HA image installs
requirements for all integrations; here only the needed ones, HA installs the rest when they're enabled.
"""
import ast
import json
import socket
import sys
import urllib.request
from concurrent.futures import ThreadPoolExecutor

# IPv4 only: where IPv6 is configured but broken, urllib waits for a timeout on every request.
_gai = socket.getaddrinfo
socket.getaddrinfo = lambda host, port, family=0, *a, **k: _gai(host, port, socket.AF_INET, *a, **k)


def get(url: str) -> bytes:
    with urllib.request.urlopen(url, timeout=30) as r:
        return r.read()


def bootstrap_domains(base: str) -> set[str]:
    """All strings from the *_INTEGRATIONS assignments in bootstrap.py."""
    tree = ast.parse(get(f"{base}/bootstrap.py"))
    out: set[str] = set()
    for node in ast.walk(tree):
        targets = []
        if isinstance(node, ast.Assign):
            targets = node.targets
        elif isinstance(node, ast.AnnAssign):
            targets = [node.target]
        if any(isinstance(t, ast.Name) and t.id.endswith("_INTEGRATIONS") for t in targets):
            out |= {c.value for c in ast.walk(node.value)
                    if isinstance(c, ast.Constant) and isinstance(c.value, str)}
    # DEFAULT_INTEGRATIONS includes *BASE_PLATFORMS, i.e. every value of the Platform enum
    # (in newer versions it's EntityPlatforms from generated/entity_platforms.py).
    for src in ("const.py", "generated/entity_platforms.py"):
        try:
            tree = ast.parse(get(f"{base}/{src}"))
        except Exception:  # noqa: BLE001
            continue
        for node in ast.walk(tree):
            if isinstance(node, ast.ClassDef) and node.name in ("Platform", "EntityPlatforms"):
                out |= {a.value.value for a in node.body
                        if isinstance(a, ast.Assign) and isinstance(a.value, ast.Constant)
                        and isinstance(a.value.value, str)}
    return {d for d in out if d.replace("_", "").isalnum()}


def main() -> None:
    version, extra = sys.argv[1], sys.argv[2:] or ["default_config"]
    base = f"https://raw.githubusercontent.com/home-assistant/core/{version}/homeassistant"
    todo = bootstrap_domains(base) | set(extra)
    seen: dict[str, dict] = {}
    with ThreadPoolExecutor(16) as ex:
        while todo:
            batch = sorted(todo - seen.keys())
            todo = set()

            def load(dom):
                try:
                    return dom, json.loads(get(f"{base}/components/{dom}/manifest.json"))
                except Exception as e:  # noqa: BLE001
                    print(f"# skipped {dom}: {e}", file=sys.stderr)
                    return dom, {}

            for dom, man in ex.map(load, batch):
                seen[dom] = man
                todo |= set(man.get("dependencies", [])) | set(man.get("after_dependencies", []))
            todo -= seen.keys()
    reqs = sorted({r for m in seen.values() for r in m.get("requirements", [])}, key=str.lower)
    print(f"# {len(seen)} integrations, {len(reqs)} packages: {', '.join(sorted(seen))}")
    print("\n".join(reqs))


if __name__ == "__main__":
    main()
