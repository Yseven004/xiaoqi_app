#!/usr/bin/env python3
"""Start a per-task Squid proxy with an exact-domain allowlist."""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys


DOMAIN_RE = re.compile(r"^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$")
DENIED_DESTINATIONS = (
    "0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 "
    "172.16.0.0/12 192.0.0.0/24 192.168.0.0/16 198.18.0.0/15 "
    "224.0.0.0/4 240.0.0.0/4 ::/128 ::1/128 fc00::/7 fe80::/10 ff00::/8"
)


def main() -> int:
    try:
        domains = json.loads(os.environ.get("XIAOQI_ALLOWED_DOMAINS", "[]"))
    except json.JSONDecodeError:
        return 2
    if not isinstance(domains, list) or not domains or len(domains) > 10:
        return 2
    try:
        config = config_for_domains(domains)
    except ValueError:
        return 2
    config_path = "/tmp/squid.conf"
    with open(config_path, "w", encoding="ascii") as output:
        output.write(config)
    return subprocess.call(["/usr/sbin/squid", "-N", "-f", config_path])


def config_for_domains(domains: list[object]) -> str:
    normalized = sorted({str(value).strip().lower().rstrip(".") for value in domains})
    if not normalized or len(normalized) > 10 or any(not DOMAIN_RE.fullmatch(value) for value in normalized):
        raise ValueError("invalid destination domain")
    return "\n".join([
        "http_port 3128",
        "acl Safe_ports port 80 443",
        "acl SSL_ports port 443",
        "acl CONNECT method CONNECT",
        f"acl denied_destinations dst {DENIED_DESTINATIONS}",
        "acl allowed_domains dstdomain " + " ".join(normalized),
        "http_access deny !Safe_ports",
        "http_access deny CONNECT !SSL_ports",
        "http_access deny denied_destinations",
        "http_access allow allowed_domains",
        "http_access deny all",
        "cache deny all",
        "cache_store_log none",
        "access_log none",
        "cache_log /dev/null",
        "pid_filename /tmp/squid.pid",
        "coredump_dir /tmp",
        "visible_hostname xiaoqi-sandbox-proxy",
        "",
    ])


if __name__ == "__main__":
    raise SystemExit(main())
