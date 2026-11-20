#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="/opt/respondd"
SERVICE_FILE="/etc/systemd/system/respondd.service"

IFACE="br-ff"
MESHIF="bat0"
HOSTNAME_VAL=""
NODE_ID_VAL=""
MAC_VAL=""
CONTACT_VAL="stephan@msc-hartha.de"
DOMAIN_VAL="ffhar"
SITE_CODE_VAL="ffmsn"
DOMAIN_CODE_VAL="ffhar"
ROLE_VAL="node"
LATITUDE_VAL="51.104254564"
LONGITUDE_VAL="12.97875613"
HARDWARE_MODEL_VAL=""
NPROC_VAL=""
FIRMWARE_BASE_VAL=""
FIRMWARE_RELEASE_VAL="custom-offloader"
ONLINE_VAL="true"
GATEWAY_VAL=""

usage() {
  cat <<'EOF'
Usage: install-respondd.sh [options]

Options:
  --iface <name>             Interface for MAC/node_id (default: br-ff)
  --meshif <name>            batman-adv mesh interface (default: bat0)
  --hostname <name>          Override hostname (default: existing or system hostname)
  --node-id <hex>            Override node_id (default: MAC without colons)
  --mac <aa:bb:cc:dd:ee:ff>  Override MAC (default: /sys/class/net/<iface>/address)
  --contact <email>          Contact address (default: stephan@msc-hartha.de)
  --domain <domain>          Domain / site_code fallback (default: ffhar)
  --site-code <code>         Site code (default: ffmsn)
  --domain-code <code>       Domain code (default: ffhar)
  --role <role>              System role (default: node)
  --latitude <float>         Latitude (default: 51.104254564)
  --longitude <float>        Longitude (default: 12.97875613)
  --hardware-model <model>   Override hardware model
  --nproc <int>              Override CPU count
  --firmware-base <base>     Override firmware base (default: /etc/os-release ID)
  --firmware-release <rel>   Firmware release (default: custom-offloader)
  --gateway <mac_or_id>      Fallback gateway if batctl has no active '*' gateway
  --offline                  Set online=false (default: true)
  -h, --help                 Show this help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --iface) IFACE="$2"; shift 2 ;;
    --meshif) MESHIF="$2"; shift 2 ;;
    --hostname) HOSTNAME_VAL="$2"; shift 2 ;;
    --node-id) NODE_ID_VAL="$2"; shift 2 ;;
    --mac) MAC_VAL="$2"; shift 2 ;;
    --contact) CONTACT_VAL="$2"; shift 2 ;;
    --domain) DOMAIN_VAL="$2"; shift 2 ;;
    --site-code) SITE_CODE_VAL="$2"; shift 2 ;;
    --domain-code) DOMAIN_CODE_VAL="$2"; shift 2 ;;
    --role) ROLE_VAL="$2"; shift 2 ;;
    --latitude) LATITUDE_VAL="$2"; shift 2 ;;
    --longitude) LONGITUDE_VAL="$2"; shift 2 ;;
    --hardware-model) HARDWARE_MODEL_VAL="$2"; shift 2 ;;
    --nproc) NPROC_VAL="$2"; shift 2 ;;
    --firmware-base) FIRMWARE_BASE_VAL="$2"; shift 2 ;;
    --firmware-release) FIRMWARE_RELEASE_VAL="$2"; shift 2 ;;
    --gateway) GATEWAY_VAL="$2"; shift 2 ;;
    --offline) ONLINE_VAL="false"; shift 1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unbekannte Option: $1" >&2; usage; exit 1 ;;
  esac
done

mkdir -p "$INSTALL_DIR"

if [ -f "$INSTALL_DIR/respondd.py" ]; then
  cp "$INSTALL_DIR/respondd.py" "$INSTALL_DIR/respondd.py.bak.$(date +%s)"
fi
if [ -f "$INSTALL_DIR/config.json" ]; then
  cp "$INSTALL_DIR/config.json" "$INSTALL_DIR/config.json.bak.$(date +%s)"
fi

cat <<'EOF' > "$INSTALL_DIR/respondd.py"
#!/usr/bin/env python3
import socket, struct, json, zlib, subprocess, os, re, time

CONFIG_PATH = "/opt/respondd/config.json"

def load_cfg():
    with open(CONFIG_PATH, "r", encoding="utf-8") as f:
        return json.load(f)

CFG = load_cfg()

def mac(i):
    try:
        return open(f"/sys/class/net/{i}/address", "r", encoding="utf-8").read().strip()
    except OSError:
        return CFG.get("mac", "02:00:00:00:00:01")

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
        "clients": {"total": 0, "wifi": 0, "wifi24": 0, "wifi5": 0},
    }

def info():
    mod_default = "Raspberry Pi"
    if os.path.exists("/proc/device-tree/model"):
        mod_default = open("/proc/device-tree/model", "rb").read().decode("utf-8", "ignore").strip("\x00").strip()
    mod = CFG.get("hardware_model") or mod_default
    node_mac = CFG.get("mac") or mac("br-ff")
    node_id = CFG.get("node_id") or node_mac.replace(":", "")
    sys_info = {
        "role": CFG.get("role", "node"),
        "site_code": CFG.get("site_code", CFG.get("domain", "ffmsn")),
    }
    if CFG.get("domain_code"):
        sys_info["domain_code"] = CFG["domain_code"]
    d = {
        "node_id": node_id,
        "hostname": CFG["hostname"],
        "owner": {"contact": CFG["contact"]},
        "system": sys_info,
        "hardware": {
            "model": mod,
            "nproc": int(CFG.get("nproc") or os.cpu_count() or 1),
        },
        "software": {
            "autoupdater": {"enabled": False},
            "batman-adv": {"version": "kernel", "compat": 15},
            "fastd": {"enabled": True},
            "firmware": {
                "base": CFG.get("firmware_base", "Linux"),
                "release": CFG.get("firmware_release", "custom-offloader"),
            },
        },
        "network": {
            "mac": node_mac,
            "mesh": {"bat0": {"interfaces": {"tunnel": [mac("ffmsn-vpn")]}}},
        },
    }
    if CFG.get("latitude") is not None and CFG.get("longitude") is not None:
        d["location"] = {
            "latitude": float(CFG["latitude"]),
            "longitude": float(CFG["longitude"]),
        }
    return d

def neigh():
    n = {}
    try:
        out = subprocess.check_output(
            ["batctl", "meshif", "bat0", "o", "-H"],
            stderr=subprocess.DEVNULL,
            text=True,
        )
        for l in out.splitlines():
            m = re.search(
                r"([0-9a-f:]{17})\s+\d+\.\d+s\s+\(\s*(\d+)\)\s+([0-9a-f:]{17})\s+\[\s*([^\]]+)\]",
                l.lower(),
            )
            if m and m.group(1) == m.group(3):
                n.setdefault(m.group(4).strip(), {"neighbours": {}})["neighbours"].setdefault(
                    m.group(1), {"tq": int(m.group(2)), "lastseen": 0.1}
                )
    except Exception:
        pass
    return {"node_id": CFG.get("node_id") or mac("br-ff").replace(":", ""), "batadv": n}

while not os.path.exists("/sys/class/net/br-ff"):
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
chmod +x "$INSTALL_DIR/respondd.py"

cat <<'EOF' > "$INSTALL_DIR/generate-config.py"
#!/usr/bin/env python3
import argparse
import json
import os
import re
import socket
import subprocess


def read_text(path: str, default: str = "") -> str:
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            return f.read().strip("\x00").strip()
    except OSError:
        return default


def get_mac(iface: str, fallback: str = "02:00:00:00:00:01") -> str:
    addr = read_text(f"/sys/class/net/{iface}/address", fallback).lower()
    return addr if re.match(r"^[0-9a-f]{2}(:[0-9a-f]{2}){5}$", addr) else fallback


def detect_active_gateway(meshif: str = "bat0"):
    try:
        out = subprocess.check_output(
            ["batctl", "meshif", meshif, "gwl", "-H"],
            stderr=subprocess.DEVNULL,
            text=True,
        )
        for line in out.splitlines():
            if "*" in line:
                m = re.search(r"([0-9a-f]{2}(?::[0-9a-f]{2}){5})", line.lower())
                if m:
                    return m.group(1)
    except (subprocess.SubprocessError, FileNotFoundError):
        pass
    return None


def detect_firmware_base() -> str:
    os_release = read_text("/etc/os-release")
    for line in os_release.splitlines():
        if line.startswith("ID="):
            return line.split("=", 1)[1].strip().strip('"').capitalize()
    return "Linux"


def build_config(args: argparse.Namespace) -> dict:
    existing = {}
    if args.existing_config and os.path.exists(args.existing_config):
        try:
            with open(args.existing_config, "r", encoding="utf-8") as f:
                loaded = json.load(f)
                if isinstance(loaded, dict):
                    existing = loaded
        except (OSError, json.JSONDecodeError):
            existing = {}

    mac_addr = args.mac or get_mac(args.iface)
    node_id = args.node_id or mac_addr.replace(":", "")
    hostname = args.hostname or existing.get("hostname") or socket.gethostname()
    hardware_model = (
        args.hardware_model
        or existing.get("hardware_model")
        or read_text("/proc/device-tree/model", "Linux Host")
    )
    nproc = args.nproc if args.nproc is not None else (os.cpu_count() or 1)
    firmware_base = args.firmware_base or existing.get("firmware_base") or detect_firmware_base()
    firmware_release = args.firmware_release or existing.get("firmware_release") or "custom-offloader"

    active_gw = detect_active_gateway(args.meshif)
    gateway = active_gw or args.gateway or existing.get("gateway")

    return {
        "hostname": hostname,
        "node_id": node_id,
        "mac": mac_addr,
        "contact": args.contact if args.contact is not None else existing.get("contact", "stephan@msc-hartha.de"),
        "domain": args.domain if args.domain is not None else existing.get("domain", "ffhar"),
        "site_code": args.site_code if args.site_code is not None else existing.get("site_code", "ffmsn"),
        "domain_code": args.domain_code if args.domain_code is not None else existing.get("domain_code", "ffhar"),
        "role": args.role if args.role is not None else existing.get("role", "node"),
        "latitude": args.latitude if args.latitude is not None else existing.get("latitude", 51.104254564),
        "longitude": args.longitude if args.longitude is not None else existing.get("longitude", 12.97875613),
        "hardware_model": hardware_model,
        "nproc": nproc,
        "firmware_base": firmware_base,
        "firmware_release": firmware_release,
        "online": True if args.online is None else args.online,
        "gateway": gateway,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate flat Freifunk respondd config.json per client.")
    parser.add_argument("-o", "--output", default="/opt/respondd/config.json")
    parser.add_argument("--existing-config", default="/opt/respondd/config.json")
    parser.add_argument("--iface", default="br-ff")
    parser.add_argument("--meshif", default="bat0")
    parser.add_argument("--hostname")
    parser.add_argument("--node-id")
    parser.add_argument("--mac")
    parser.add_argument("--contact")
    parser.add_argument("--domain")
    parser.add_argument("--site-code")
    parser.add_argument("--domain-code")
    parser.add_argument("--role")
    parser.add_argument("--latitude", type=float)
    parser.add_argument("--longitude", type=float)
    parser.add_argument("--hardware-model")
    parser.add_argument("--nproc", type=int)
    parser.add_argument("--firmware-base")
    parser.add_argument("--firmware-release")
    parser.add_argument("--gateway")
    parser.add_argument("--online", dest="online", action="store_true", default=None)
    parser.add_argument("--offline", dest="online", action="store_false")
    args = parser.parse_args()

    cfg = build_config(args)
    out_dir = os.path.dirname(os.path.abspath(args.output))
    os.makedirs(out_dir, exist_ok=True)
    tmp_path = f"{args.output}.tmp.{os.getpid()}"
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")
    os.replace(tmp_path, args.output)


if __name__ == "__main__":
    main()
EOF
chmod +x "$INSTALL_DIR/generate-config.py"

cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Freifunk respondd daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $INSTALL_DIR/respondd.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

GEN_CMD=(
  "$INSTALL_DIR/generate-config.py"
  --output "$INSTALL_DIR/config.json"
  --iface "$IFACE"
  --meshif "$MESHIF"
  --contact "$CONTACT_VAL"
  --domain "$DOMAIN_VAL"
  --site-code "$SITE_CODE_VAL"
  --domain-code "$DOMAIN_CODE_VAL"
  --role "$ROLE_VAL"
  --latitude "$LATITUDE_VAL"
  --longitude "$LONGITUDE_VAL"
  --firmware-release "$FIRMWARE_RELEASE_VAL"
)
[ -n "$HOSTNAME_VAL" ] && GEN_CMD+=(--hostname "$HOSTNAME_VAL")
[ -n "$NODE_ID_VAL" ] && GEN_CMD+=(--node-id "$NODE_ID_VAL")
[ -n "$MAC_VAL" ] && GEN_CMD+=(--mac "$MAC_VAL")
[ -n "$HARDWARE_MODEL_VAL" ] && GEN_CMD+=(--hardware-model "$HARDWARE_MODEL_VAL")
[ -n "$NPROC_VAL" ] && GEN_CMD+=(--nproc "$NPROC_VAL")
[ -n "$FIRMWARE_BASE_VAL" ] && GEN_CMD+=(--firmware-base "$FIRMWARE_BASE_VAL")
[ -n "$GATEWAY_VAL" ] && GEN_CMD+=(--gateway "$GATEWAY_VAL")
[ "$ONLINE_VAL" = "false" ] && GEN_CMD+=(--offline)

"${GEN_CMD[@]}"
python3 -m json.tool "$INSTALL_DIR/config.json" > /dev/null

systemctl daemon-reload
systemctl enable respondd.service
systemctl restart respondd.service
