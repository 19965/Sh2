#!/bin/bash

# CONFIG ========
CT_NAME="myct"
PORT1_HOST=5000
PORT1_CT=5000
PORT2_HOST=6000
PORT2_CT=6000
# ===============

echo "[1] Installing LXC & tools..."
apt update -y
apt install -y lxc lxc-templates bridge-utils debootstrap iptables-persistent curl wget

echo "[2] Creating LXC container $CT_NAME..."
lxc-create -n $CT_NAME -t download -- --dist ubuntu --release jammy --arch amd64

echo "[3] Starting container..."
lxc-start -n $CT_NAME
sleep 5

echo "[4] Getting container IP..."
CT_IP=$(lxc-info -n $CT_NAME -iH)
echo "Container IP = $CT_IP"

echo "[5] Installing basic tools inside container..."
lxc-attach -n $CT_NAME -- bash -c "apt update -y && apt install -y curl wget"

echo "[6] Enabling IP forwarding on host..."
sysctl -w net.ipv4.ip_forward=1
sed -i 's/^#*net.ipv4.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf

echo "[7] Creating iptables port-forwarding rules..."

# Port 1
iptables -t nat -A PREROUTING -p tcp --dport $PORT1_HOST -j DNAT --to-destination $CT_IP:$PORT1_CT
iptables -A FORWARD -p tcp -d $CT_IP --dport $PORT1_CT -j ACCEPT

# Port 2
iptables -t nat -A PREROUTING -p tcp --dport $PORT2_HOST -j DNAT --to-destination $CT_IP:$PORT2_CT
iptables -A FORWARD -p tcp -d $CT_IP --dport $PORT2_CT -j ACCEPT

# Masquerade for outbound traffic
iptables -t nat -A POSTROUTING -s $CT_IP/32 -j MASQUERADE

echo "[8] Saving iptables rules..."
netfilter-persistent save

echo "====================================="
echo " DONE!"
echo "====================================="
echo "Container: $CT_NAME"
echo "Container IP: $CT_IP"
echo ""
echo "Port forwarding enabled:"
echo "  HOST:$PORT1_HOST  ->  CT:$PORT1_CT"
echo "  HOST:$PORT2_HOST  ->  CT:$PORT2_CT"
echo "====================================="
