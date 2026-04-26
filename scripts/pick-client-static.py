#!/usr/bin/env python3
"""Pick a stable manual IPv4 in the same subnet as the current lease (any prefix length)."""
from __future__ import annotations

import ipaddress
import os
import sys

# Usage:  ACT_CIDR=10.24.65.80/24 CLIENT_DEMO_HOST_LAST=200  python3 pick-client-static.py [ACT_CIDR]
# Defaults: host index from env CLIENT_DEMO_HOST_LAST (1–254 for /24 = last octet; otherwise offset into .hosts())


def main() -> None:
    act = os.environ.get("ACT_CIDR") or (sys.argv[1] if len(sys.argv) > 1 else "")
    if not act:
        print("need ACT_CIDR or argv[1]", file=sys.stderr)
        sys.exit(2)
    want = int(os.environ.get("CLIENT_DEMO_HOST_LAST", "200"))
    iface = ipaddress.ip_interface(act)
    n = iface.network
    hosts = [x for x in n.hosts()]
    if not hosts:
        print(f"{iface.with_prefixlen}", end="")
        return
    if n.prefixlen == 24:
        parts = str(n.network_address).split(".")
        if len(parts) == 4:
            last = min(max(2, want), 254)
            cand = ipaddress.IPv4Address(".".join(parts[:3] + [str(last)]))
            if cand in n:
                print(f"{cand}/24", end="")
                return
    # /28, /23, etc.
    idx = min(max(0, want - 1), len(hosts) - 1)
    print(f"{hosts[idx]}/{n.prefixlen}", end="")


if __name__ == "__main__":
    main()
