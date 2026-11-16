#!/bin/bash
set -e

BASE_IF="eth0"
CLIENT_VLAN="10"
MESH_VLAN="20"
VPN_MTU="1426"
FASTD_METHOD="salsa2012+umac"
BATMAN_ALGO="BATMAN_IV"

PEER1_HOST="vpn01.freifunk-mittelsachsen.de"
PEER1_PORT="10000"
PEER1_KEY="4f5e13d3afa24ed88bc790c4fdae4382359e65a10f46a78c4fb8c9d9e509e986"

PEER2_HOST="vpn02.freifunk-mittelsachsen.de"
PEER2_PORT="10000"
PEER2_KEY="21d9a4433052a6e5ee193c943b4f295778fde2cd88f698fd0344a7097420acbf"

[ "$EUID" -ne 0 ] && echo "Bitte mit sudo ausführen!" && exit 1

CLIENT_IF="${BASE_IF}.${CLIENT_VLAN}"
MESH_IF="${BASE_IF}.${MESH_VLAN}"
FIXED_MAC=$(cat /sys/class/net/${BASE_IF}/address | sed "s/^../02/")

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ifupdown fastd batctl bridge-utils iproute2 vlan tcpdump python3

modprobe batman_adv
modprobe 8021q
grep -q "^batman_adv" /etc/modules || echo "batman_adv" >> /etc/modules
grep -q "^8021q" /etc/modules || echo "8021q" >> /etc/modules

mkdir -p /etc/fastd/ffmsn/peers
if [ ! -f /etc/fastd/ffmsn/secret.key ]; then
  fastd --generate-key > /etc/fastd/ffmsn/keypair.txt
  grep "Secret:" /etc/fastd/ffmsn/keypair.txt | awk '{print $2}' > /etc/fastd/ffmsn/secret.key
  grep "Public:" /etc/fastd/ffmsn/keypair.txt | awk '{print $2}' > /etc/fastd/ffmsn/public.key
  chmod 600 /etc/fastd/ffmsn/secret.key
fi
SECRET_KEY=$(cat /etc/fastd/ffmsn/secret.key)

cat <<EOF > /etc/fastd/ffmsn/fastd.conf
log level warn;
interface "ffmsn-vpn";
method "$FASTD_METHOD";
bind any:10000;
secret "$SECRET_KEY";
mtu $VPN_MTU;
peer limit 2;
include peers from "peers";
on up "ip link set up dev \$INTERFACE; batctl meshif bat0 if add \$INTERFACE; dhclient -nw br-ff &";
on down "batctl meshif bat0 if del \$INTERFACE";
EOF

echo -e "key \"$PEER1_KEY\";\nremote ipv4 \"$PEER1_HOST\" port $PEER1_PORT;" > /etc/fastd/ffmsn/peers/vpn01
echo -e "key \"$PEER2_KEY\";\nremote \"$PEER2_HOST\" port $PEER2_PORT;" > /etc/fastd/ffmsn/peers/vpn02

mkdir -p /etc/dhcp/dhclient-enter-hooks.d
cat <<'EOF' > /etc/dhcp/dhclient-enter-hooks.d/freifunk-no-default-route
if [ "$interface" = "br-ff" ]; then
    unset new_routers
fi
EOF

mkdir -p /etc/network/interfaces.d
grep -q "source /etc/network/interfaces.d/\*" /etc/network/interfaces || echo "source /etc/network/interfaces.d/*" >> /etc/network/interfaces

cat <<EOF > /etc/network/interfaces.d/freifunk
# VLAN 10: Freifunk-Client-Netz (kommt in br-ff)
auto $CLIENT_IF
iface $CLIENT_IF inet manual
    vlan-raw-device $BASE_IF
    up ip link set \$IFACE up

# VLAN 20: Echtes B.A.T.M.A.N.-Mesh-Interface (kommt direkt in bat0)
auto $MESH_IF
iface $MESH_IF inet manual
    vlan-raw-device $BASE_IF
    up ip link set \$IFACE up
    post-up batctl meshif bat0 if add \$IFACE || true
    pre-down batctl meshif bat0 if del \$IFACE || true

# B.A.T.M.A.N.-adv Mesh-Instanz (bündelt VPN + VLAN 20)
auto bat0
iface bat0 inet manual
    pre-up batctl ra $BATMAN_ALGO
    pre-up ip link add name bat0 type batadv
    pre-up ip link set dev bat0 mtu $VPN_MTU
    up ip link set \$IFACE up
    post-up batctl meshif bat0 gw_mode client || true
    post-up batctl meshif bat0 if add $MESH_IF || true
    post-down ip link del bat0

# Client-Bridge (bündelt NUR das fertige Client-Netz aus bat0 + VLAN 10)
auto br-ff
iface br-ff inet manual
    hwaddress ether $FIXED_MAC
    bridge_ports $CLIENT_IF bat0
    bridge_stp off
    bridge_waitport 0
    bridge_fd 0
    pre-up sysctl -w net.ipv6.conf.br-ff.disable_ipv6=0 || true
    pre-up sysctl -w net.ipv6.conf.br-ff.accept_ra=1 || true
    up ip link set \$IFACE up
    post-up ip rule add from 10.23.0.0/18 table 42 || true
    post-up ip route add 10.23.0.0/18 dev br-ff table 42 || true
    post-up ip route add default via 10.23.0.1 dev br-ff table 42 || true
    pre-down ip rule del from 10.23.0.0/18 table 42 || true
EOF

if [ -d /etc/NetworkManager/conf.d ]; then
  echo -e "[keyfile]\nunmanaged-devices=interface-name:$CLIENT_IF;interface-name:$MESH_IF;interface-name:bat0;interface-name:br-ff;interface-name:ffmsn-vpn" > /etc/NetworkManager/conf.d/99-freifunk-unmanaged.conf
  systemctl reload NetworkManager || true
fi

systemctl enable networking fastd@ffmsn
echo "TEIL 1 FERTIG! Feste Bridge-MAC: $FIXED_MAC | Public Key: $(cat /etc/fastd/ffmsn/public.key)"
