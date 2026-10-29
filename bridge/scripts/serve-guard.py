#!/usr/bin/env python3
"""Guard rails around `tailscale serve`, so the Bridge can only ever touch its
own HTTPS port.

  serve-guard.py free  <status.json> <port>              exit 0 free, 3 already served
  serve-guard.py guard <before.json> <after.json> <port> exit 0 = every other
                                                         served port is unchanged

The existing 8443 (Usage/Console) and 8444 (Hermes dashboard/Conduit) entries
must never be modified, reordered or dropped by a Bridge install.
"""

import json
import sys


def ports_of(status):
    """Returns {port: {"tcp": ..., "web": ...}} for one serve status document."""
    ports = {}
    for port, config in (status.get("TCP") or {}).items():
        ports.setdefault(str(port), {"tcp": config, "web": {}})
    for hostport, config in (status.get("Web") or {}).items():
        port = hostport.rsplit(":", 1)[-1]
        ports.setdefault(str(port), {"tcp": None, "web": {}})["web"][hostport] = config
    return ports


def load(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def main(argv):
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    command = argv[1]

    if command == "free":
        status, target = load(argv[2]), str(argv[3])
        ports = ports_of(status)
        if target in ports:
            print(f"port {target} is already served:\n{json.dumps(ports[target], indent=2)}")
            return 3
        print(f"port {target} is free")
        return 0

    if command == "guard":
        before, after, target = load(argv[2]), load(argv[3]), str(argv[4])
        before_ports, after_ports = ports_of(before), ports_of(after)
        changed = []
        for port, config in before_ports.items():
            if port == target:
                continue
            if after_ports.get(port) != config:
                changed.append(port)
        if changed:
            print(f"refusing: existing serve entries changed on port(s) {', '.join(sorted(changed))}")
            print(json.dumps({p: after_ports.get(p) for p in changed}, indent=2))
            return 1
        untouched = sorted(p for p in before_ports if p != target)
        print(f"unchanged: {', '.join(untouched) if untouched else '(none)'}")
        return 0

    print(f"unknown command: {command}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
