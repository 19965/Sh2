#!/bin/bash

# ================================
# CONFIG
# ================================
CT_NAME="myct"
PORT1_HOST=5000
PORT1_CT=5000
PORT2_HOST=6000
PORT2_CT=6000
GITHUB_SCRIPT_URL="https://ghproxy.net/https://raw.githubusercontent.com/19965/sh2/main/ub.sh"

# ================================
# INSTALL LXC & DEPENDENCIES
# ================================
echo "[1] Installing LXC & tools..."
apt update -y
apt install -y lxc lxc-templates bridge-utils debootstrap iptables-persistent curl wget

# ================================
# CREATE CONTAINER
# ================================
echo "[2] Creating LXC container $CT_NAME..."
lxc-create -n $CT_NAME -t download -- --dist ubuntu --release jammy --arch amd64

echo "[3] Starting container..."
lxc-start -n $CT_NAME
sleep 5

# ================================
# GET CONTAINER IP
# ================================
echo "[4] Getting container IP..."
CT_IP=$(lxc-info -n $CT_NAME -iH)
echo "Container IP = $CT_IP"

# ================================
# ENABLE IP FORWARDING
# ================================
echo "[5] Enabling IP forwarding..."
sysctl -w net.ipv4.ip_forward=1
sed -i 's/^#*net.ipv4.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf

# ================================
# ADD NAT / PORT FORWARDING RULES
# ================================
echo "[6] Adding iptables NAT rules..."

# Port 5000
iptables -t nat -A PREROUTING -p tcp --dport $PORT1_HOST -j DNAT --to-destination $CT_IP:$PORT1_CT
iptables -A FORWARD -p tcp -d $CT_IP --dport $PORT1_CT -j ACCEPT

# Port 6000
iptables -t nat -A PREROUTING -p tcp --dport $PORT2_HOST -j DNAT --to-destination $CT_IP:$PORT2_CT
iptables -A FORWARD -p tcp -d $CT_IP --dport $PORT2_CT -j ACCEPT

# Port 25 (SMTP inbound)
iptables -t nat -A PREROUTING -p tcp --dport 25 -j DNAT --to-destination $CT_IP:25
iptables -A FORWARD -p tcp -d $CT_IP --dport 25 -j ACCEPT

# Port 587 (SMTP submission)
iptables -t nat -A PREROUTING -p tcp --dport 587 -j DNAT --to-destination $CT_IP:587
iptables -A FORWARD -p tcp -d $CT_IP --dport 587 -j ACCEPT

# Port 465 (SMTPS)
iptables -t nat -A PREROUTING -p tcp --dport 465 -j DNAT --to-destination $CT_IP:465
iptables -A FORWARD -p tcp -d $CT_IP --dport 465 -j ACCEPT

# Outbound NAT (internet access for container)
iptables -t nat -A POSTROUTING -s $CT_IP/32 -o eth0 -j MASQUERADE

# ================================
# SAVE RULES
# ================================
echo "[7] Saving iptables rules..."
mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4

# ================================
# INSTALL NAT AUTO-RESTORE
# ================================
echo "[8] Installing AWS iptables auto-restore fix..."

cat >/usr/local/bin/iptables-restore-loop.sh <<EOF
#!/bin/bash
RULES="/etc/iptables/rules.v4"

while true; do
    # Restore if DNAT or MASQUERADE is missing
    if ! iptables -t nat -L PREROUTING | grep -q "DNAT" || \
       ! iptables -t nat -L POSTROUTING | grep -q "MASQUERADE"; then
        echo "[*] NAT rules missing — restoring..."
        iptables-restore < "\$RULES"
    fi
    sleep 2
done
EOF

chmod +x /usr/local/bin/iptables-restore-loop.sh

# ================================
# CREATE SYSTEMD SERVICE
# ================================
echo "[9] Creating systemd service..."

cat >/etc/systemd/system/iptables-restore-loop.service <<EOF
[Unit]
Description=Restore iptables rules if they are cleared
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/iptables-restore-loop.sh
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable iptables-restore-loop.service
systemctl start iptables-restore-loop.service

# ================================
# FIX DNS INSIDE CONTAINER
# ================================
echo "[10] Fixing DNS inside container..."
lxc-attach -n $CT_NAME -- bash -c "echo 'nameserver 8.8.8.8' > /etc/resolv.conf"

# ================================
# INSTALL TOOLS + INSTALLER INSIDE CONTAINER
# ================================
echo "[11] Installing tools & running installer inside container..."
lxc-attach -n $CT_NAME -- bash -c "apt update -y && apt install -y curl wget nano telnet"

lxc-attach -n $CT_NAME -- bash -c "mkdir -p /opt/install"

lxc-attach -n $CT_NAME -- bash -c "wget -O /opt/install/install.sh $GITHUB_SCRIPT_URL"
lxc-attach -n $CT_NAME -- bash -c "chmod +x /opt/install/install.sh"
lxc-attach -n $CT_NAME -- bash -c "/opt/install/install.sh"

# ================================
# DONE
# ================================
echo "====================================="
echo " DONE!"
echo "====================================="
echo "Container: $CT_NAME"
echo "Container IP: $CT_IP"
echo "Forwarded Ports:"
echo "  $PORT1_HOST -> $PORT1_CT"
echo "  $PORT2_HOST -> $PORT2_CT"
echo "  25 -> 25"
echo "  587 -> 587"
echo "  465 -> 465"
echo "Auto-restore service installed: iptables-restore-loop"
echo "NAT rules will NEVER disappear on AWS"
echo "====================================="
