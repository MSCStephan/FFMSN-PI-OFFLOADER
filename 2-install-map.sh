#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="/opt/respondd"
CFG_FILE="${INSTALL_DIR}/config.json"
SCRIPT_FILE="${INSTALL_DIR}/respondd.py"
SERVICE_FILE="/etc/systemd/system/respondd.service"

mkdir -p "${INSTALL_DIR}"

if [ -f "${SCRIPT_FILE}" ]; then
    cp "${SCRIPT_FILE}" "${SCRIPT_FILE}.bak.$(date +%s)"
fi

if [ ! -f "${CFG_FILE}" ]; then
    cat > "${CFG_FILE}" <<'EOF'
{
  "gateway": "9e:8f:ba:5f:e7:fe"
}
EOF
fi

cat > "${SCRIPT_FILE}" <<'EOF'
#!/usr/bin/env python3
import json
import re
import socket
import struct
import subprocess
import time
import zlib
from pathlib import Path

CFG_PATH = Path("/opt/respondd/config.json")


def load_cfg():
    try:
        with CFG_PATH.open("r", encoding="utf-8") as f:
            data = json.load(f)
            return data if isinstance(data, dict) else {}
    except Exception:
        return {}


CFG = load_cfg()


def mac(iface):
    p = Path(f"/sys/class/net/{iface}/address")
    try:
        return p.read_text(encoding="utf-8").strip().lower()
    except OSError:
        return "00:00:00:00:00:00"


def count_clients():
    own_macs = {
        "9e:8f:ba:5f:e7:fe",
        "56:9a:01:7a:a9:1f",
        "00:00:00:00:00:00",
        "ff:ff:ff:ff:ff:ff",
    }
    if isinstance(CFG, dict) and CFG.get("gateway"):
        own_macs.add(str(CFG["gateway"]).strip().lower())

    for dev in ("br-ff", "eth0.10", "eth0.20", "ffmsn-vpn", "bat0", "eth0", "wlan0"):
        try:
            m_path = Path(f"/sys/class/net/{dev}/address")
            if m_path.exists():
                own_macs.add(m_path.read_text(encoding="utf-8").strip().lower())
        except OSError:
            pass

    clients = set()

    # 1. IPv4 ARP-Einträge auf br-ff und eth0.10 ohne blockierende Subprozesse
    try:
        with open("/proc/net/arp", "r", encoding="utf-8") as f:
            next(f, None)
            for line in f:
                parts = line.split()
                if len(parts) < 6:
                    continue
                _ip, _hw_type, flags, hw_addr, _mask, dev = parts[:6]
                hw_addr = hw_addr.strip().lower()
                if dev.strip() not in ("br-ff", "eth0.10"):
                    continue
                if flags == "0x0" or hw_addr in own_macs or hw_addr.startswith(("33:33:", "01:80:c2:")):
                    continue
                clients.add(hw_addr)
    except OSError:
        pass

    # 2. Dynamische FDB-Einträge auf eth0.10 (falls Clients nur gebridgt/geroutet werden)
    try:
        out = subprocess.check_output(
            ["bridge", "fdb", "show", "br", "br-ff"],
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=2,
        )
        for line in out.splitlines():
            parts = line.strip().lower().split()
            if len(parts) < 3 or "dev" not in parts:
                continue
            cand = parts[0]
            dev_idx = parts.index("dev")
            if dev_idx + 1 >= len(parts):
                continue
            if parts[dev_idx + 1] != "eth0.10":
                continue
            flags_tail = " ".join(parts[dev_idx + 2 :])
            if "permanent" in flags_tail or "self" in flags_tail:
                continue
            if cand in own_macs or cand.startswith(("33:33:", "01:80:c2:")):
                continue
            clients.add(cand)
    except Exception:
        pass

    return len(clients)


def stats():
    m = {}
    with open("/proc/meminfo", "r", encoding="utf-8") as f:
        for l in f:
            if ":" in l:
                k, v = l.split(":", 1)
                parts = v.split()
                if parts:
                    m[k.strip()] = int(parts[0])

    gw = CFG.get("gateway")
    try:
        out = subprocess.check_output(
            ["batctl", "meshif", "bat0", "gwl", "-H"],
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=2,
        )
        for l in out.splitlines():
            if "*" in l:
                match = re.search(r"([0-9a-f:]{17})", l.lower())
                if match:
                    gw = match.group(1)
                    break
    except Exception:
        pass

    return {
        "node_id": CFG.get("node_id") or mac("br-ff").replace(":", ""),
        "uptime": float(open("/proc/uptime", "r", encoding="utf-8").read().split()[0]),
        "loadavg": float(open("/proc/loadavg", "r", encoding="utf-8").read().split()[0]),
        "memory": {
            "total": m.get("MemTotal", 0),
            "free": m.get("MemFree", 0),
            "buffers": m.get("Buffers", 0),
            "cached": m.get("Cached", 0),
        },
        "gateway": gw,
        "clients": {"total": count_clients(), "wifi": 0, "wifi24": 0, "wifi5": 0},
    }


def info():
    hostname = socket.gethostname()
    return {
        "hostname": hostname,
        "node_id": CFG.get("node_id") or mac("br-ff").replace(":", ""),
        "network": {
            "mac": mac("br-ff"),
            "mesh": {"bat0": {"interfaces": {"tunnel": [mac("ffmsn-vpn")]}}},
        },
    }


def neigh():
    return {"bat0": {"neighbours": {}}}


if __name__ == "__main__":
    time.sleep(2)

    s = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("::", 1001))
    s.setsockopt(
        socket.IPPROTO_IPV6,
        socket.IPV6_JOIN_GROUP,
        struct.pack("16sI", socket.inet_pton(socket.AF_INET6, "ff02::2:1001"), socket.if_nametoindex("br-ff")),
    )

    while True:
        data, addr = s.recvfrom(1024)
        msg = data.decode("utf-8", "ignore").strip()
        if msg.startswith("GET "):
            cats, r = msg[4:].split(), {}
            if "nodeinfo" in cats:
                r["nodeinfo"] = info()
            if "statistics" in cats:
                r["statistics"] = stats()
            if "neighbours" in cats:
                r["neighbours"] = neigh()
            if r:
                c = zlib.compressobj(6, zlib.DEFLATED, -zlib.MAX_WBITS)
                s.sendto(c.compress(json.dumps(r).encode()) + c.flush(), addr)
EOF

chmod 0755 "${SCRIPT_FILE}"
python3 -m py_compile "${SCRIPT_FILE}"

cat > "${SERVICE_FILE}" <<'EOF'
[Unit]
Description=Freifunk respondd daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/respondd
ExecStart=/usr/bin/python3 /opt/respondd/respondd.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable respondd.service
systemctl restart respondd.service --no-block
sleep 1
systemctl status respondd.service --no-pager -n 10
