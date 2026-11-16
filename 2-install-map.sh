#!/bin/bash
set -e

[ "$EUID" -ne 0 ] && echo "Bitte mit sudo ausführen!" && exit 1

MAC_SUFFIX=$(cat /sys/class/net/eth0/address 2>/dev/null | tr -d ':' | tail -c 5 || echo "0001")
NODE_HOSTNAME="${1:-ffmsn-hartha-offloader-${MAC_SUFFIX}}"
NODE_LAT="${2:-51.0975}"
NODE_LON="${3:-12.9765}"
NODE_CONTACT="${4:-deine-neue@mail.de}"

mkdir -p /opt/respondd

cat <<EOF > /opt/respondd/config.json
{
  "hostname": "$NODE_HOSTNAME",
  "contact": "$NODE_CONTACT",
  "domain": "hartha",
  "latitude": $NODE_LAT,
  "longitude": $NODE_LON
}
EOF

cat <<'EOF' > /opt/respondd/respondd.py
#!/usr/bin/env python3
import socket, struct, json, zlib, subprocess, os, re, time

with open("/opt/respondd/config.json") as f:
    CFG = json.load(f)

def mac(i):
    try: return open(f"/sys/class/net/{i}/address").read().strip()
    except: return "02:00:00:00:00:01"

def stats():
    m = {}
    for l in open("/proc/meminfo"):
        k, v = l.split(":")
        m[k.strip()] = int(v.split().pop(0))
    gw = None
    try:
        for l in subprocess.check_output(["batctl", "meshif", "bat0", "gwl", "-H"], stderr=subprocess.DEVNULL).decode().splitlines():
            if "*" in l: gw = re.search(r"([0-9a-f:]{17})", l).group(1)
    except: pass
    return {
        "node_id": mac("br-ff").replace(":", ""),
        "uptime": float(open("/proc/uptime").read().split().pop(0)),
        "loadavg": float(open("/proc/loadavg").read().split().pop(0)),
        "memory": {"total": m.get("MemTotal",0), "free": m.get("MemFree",0), "buffers": m.get("Buffers",0), "cached": m.get("Cached",0)},
        "gateway": gw, "clients": {"total": 0, "wifi": 0, "wifi24": 0, "wifi5": 0}
    }

def info():
    mod = open("/proc/device-tree/model", "rb").read().decode("utf-8", "ignore").strip("\x00").strip() if os.path.exists("/proc/device-tree/model") else "Raspberry Pi"
    d = {
        "node_id": mac("br-ff").replace(":", ""), "hostname": CFG["hostname"],
        "owner": {"contact": CFG["contact"]}, "system": {"role": "offloader", "site_code": CFG["domain"]},
        "hardware": {"model": mod, "nproc": os.cpu_count() or 1},
        "software": {"autoupdater": {"enabled": False}, "batman-adv": {"version": "kernel", "compat": 15}, "fastd": {"enabled": True}},
        "network": {"mac": mac("br-ff"), "mesh": {"bat0": {"interfaces": {"tunnel": list((mac("ffmsn-vpn"),))}}}}
    }
    if CFG.get("latitude") and CFG.get("longitude"):
        d["location"] = {"latitude": float(CFG["latitude"]), "longitude": float(CFG["longitude"])}
    return d

def neigh():
    n = {}
    try:
        for l in subprocess.check_output(["batctl", "meshif", "bat0", "o", "-H"], stderr=subprocess.DEVNULL).decode().splitlines():
            m = re.search(r"([0-9a-f:]{17})\s+\d+\.\d+s\s+\(\s*(\d+)\)\s+([0-9a-f:]{17})\s+\[\s*([^\]]+)\]", l)
            if m and m.group(1) == m.group(3):
                n.setdefault(m.group(4).strip(), {"neighbours": {}})["neighbours"].setdefault(m.group(1), {"tq": int(m.group(2)), "lastseen": 0.1})
    except: pass
    return {"node_id": mac("br-ff").replace(":", ""), "batadv": n}

while not os.path.exists("/sys/class/net/br-ff"):
    time.sleep(2)

s = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("::", 1001))
s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_JOIN_GROUP, struct.pack("16sI", socket.inet_pton(socket.AF_INET6, "ff02::2:1001"), socket.if_nametoindex("br-ff")))

while True:
    data, addr = s.recvfrom(1024)
    msg = data.decode("utf-8", "ignore").strip()
    if msg.startswith("GET "):
        cats, r = msg[4:].split(), {}
        if "nodeinfo" in cats: r["nodeinfo"] = info()
        if "statistics" in cats: r["statistics"] = stats()
        if "neighbours" in cats: r["neighbours"] = neigh()
        if r:
            c = zlib.compressobj(6, zlib.DEFLATED, -zlib.MAX_WBITS)
            s.sendto(c.compress(json.dumps(r).encode()) + c.flush(), addr)
EOF

chmod +x /opt/respondd/respondd.py

cat <<EOF > /etc/systemd/system/respondd.service
[Unit]
Description=Freifunk respondd daemon
After=network-online.target fastd@ffmsn.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/respondd/respondd.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable respondd
echo "TEIL 2 FERTIG! Knoten '$NODE_HOSTNAME' ($NODE_CONTACT) eingerichtet."
