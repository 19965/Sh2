#!/bin/bash

# CONFIG ========
CT_NAME="myct"
PORT1_HOST=5000
PORT1_CT=5000
PORT2_HOST=6000
PORT2_CT=6000
GITHUB_SCRIPT_URL="https://ghproxy.net/https://raw.githubusercontent.com/19965/sh2/main/ub.sh"
# =================

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

echo "[5] Installing curl/wget inside container..."
lxc-attach -n $CT_NAME -- bash -c "apt update -y && apt install -y curl wget"

echo "[6] Preparing directory..."
lxc-attach -n $CT_NAME -- bash -c "mkdir -p /opt/install"

echo "[7] Downloading installer..."
lxc-attach -n $CT_NAME -- bash -c "wget -O /opt/install/install.sh $GITHUB_SCRIPT_URL"

echo "[8] Making script executable..."
lxc-attach -n $CT_NAME -- bash -c "chmod +x /opt/install/install.sh"

echo "[9] Running installer script..."
lxc-attach -n $CT_NAME -- bash -c "/opt/install/install.sh"

echo "[9] Enabling IP forwarding..."
sysctl -w net.ipv4.ip_forward=1
sed -i 's/^#*net.ipv4.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf

echo "[10] Creating iptables port forwarding rules..."

# PORT 1
iptables -t nat -A PREROUTING -p tcp --dport $PORT1_HOST -j DNAT --to-destination $CT_IP:$PORT1_CT
iptables -A FORWARD -p tcp -d $CT_IP --dport $PORT1_CT -j ACCEPT

# PORT 2
iptables -t nat -A PREROUTING -p tcp --dport $PORT2_HOST -j DNAT --to-destination $CT_IP:$PORT2_CT
iptables -A FORWARD -p tcp -d $CT_IP --dport $PORT2_CT -j ACCEPT

# Masquerade
iptables -t nat -A POSTROUTING -s $CT_IP/32 -j MASQUERADE

echo "[11] Saving iptables rules..."
netfilter-persistent save

echo "====================================="
echo " DONE!"
echo "====================================="
echo "Container: $CT_NAME"
echo "Container IP: $CT_IP"
echo "Port forwarding:"
echo "  HOST:$PORT1_HOST  ->  CT:$PORT1_CT"
echo "  HOST:$PORT2_HOST  ->  CT:$PORT2_CT"
echo "====================================="
