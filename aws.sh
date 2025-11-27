#!/bin/bash
set -euo pipefail

# create_lxc_aws.sh
# Usage: run as root on an AWS EC2 instance

# ================================
# CONFIG
# ================================
CT_NAME="myct"
PORT1_HOST=5000
PORT1_CT=5000
PORT2_HOST=6000
PORT2_CT=6000
GITHUB_SCRIPT_URL="https://ghproxy.net/https://raw.githubusercontent.com/19965/sh2/main/ub.sh"
IPTABLES_RULES_FILE="/etc/iptables/rules.v4"
LXC_ROOT="/var/lib/lxc"

echo "Starting LXC setup and container creation..."

# ================================
# CLEANUP OLD SETUP
# ================================
echo "[0] Cleaning up any previous installation..."

# Stop and disable restore loop if it exists
if systemctl is-active --quiet iptables-restore-loop.service 2>/dev/null; then
    echo "  - Stopping iptables-restore-loop service..."
    systemctl stop iptables-restore-loop.service
fi
if systemctl is-enabled --quiet iptables-restore-loop.service 2>/dev/null; then
    systemctl disable iptables-restore-loop.service
fi

# Stop and destroy existing container if it exists
if lxc-info -n "$CT_NAME" >/dev/null 2>&1; then
    echo "  - Stopping and removing existing container $CT_NAME..."
    lxc-stop -n "$CT_NAME" -t 10 || true
    lxc-destroy -n "$CT_NAME" || true
fi

# Flush all iptables rules
echo "  - Flushing all iptables rules..."
iptables -F
iptables -t nat -F
iptables -X
iptables -t nat -X
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

# ================================
# INSTALL LXC & DEPENDENCIES
# ================================
echo "[1] Installing LXC & tools..."
apt update -y
DEBIAN_FRONTEND=noninteractive apt install -y lxc lxc-templates bridge-utils debootstrap iptables-persistent curl wget

# Ensure sysctl allows forwarding
echo "[2] Ensuring IP forwarding is enabled on host..."
sysctl -w net.ipv4.ip_forward=1
grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf

# ================================
# CREATE & START CONTAINER
# ================================
echo "[3] Creating container $CT_NAME (Ubuntu jammy)..."
lxc-create -n "$CT_NAME" -t download -- --dist ubuntu --release jammy --arch amd64

echo "[4] Starting container..."
lxc-start -n "$CT_NAME"

# Wait for container to have an IP
echo "[5] Waiting for container to obtain an IP..."
CT_IP=""
for i in {1..30}; do
    CT_IP=$(lxc-info -n "$CT_NAME" -iH 2>/dev/null || true)
    if [[ -n "$CT_IP" && "$CT_IP" != " " && "$CT_IP" != "127.0.0.1" ]]; then
        break
    fi
    sleep 2
done

if [[ -z "${CT_IP:-}" ]]; then
    echo "ERROR: could not detect container IP. Check 'lxc-info -n $CT_NAME -iH'. Exiting."
    exit 1
fi

echo "Container IP = $CT_IP"

# Detect LXC bridge subnet
LXC_BRIDGE_IF="lxcbr0"
LXC_SUBNET=""

if ip addr show dev "${LXC_BRIDGE_IF}" >/dev/null 2>&1; then
    LXC_SUBNET=$(ip -o -f inet addr show dev "${LXC_BRIDGE_IF}" | awk '{print $4}' | head -n1)
fi

# Fallback: infer from container IP
if [[ -z "${LXC_SUBNET:-}" ]]; then
    LXC_SUBNET="${CT_IP%.*}.0/24"
fi

echo "Using LXC subnet for NAT: $LXC_SUBNET"

# ================================
# DETECT HOST DEFAULT OUTBOUND INTERFACE
# ================================
HOST_OUT_IF="$(ip route get 8.8.8.8 2>/dev/null | awk -- '{for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1); exit}}}')"

if [[ -z "${HOST_OUT_IF}" ]]; then
    # Fallback common names
    for cand in eth0 ens5 ens3; do
        if ip link show "$cand" >/dev/null 2>&1; then
            HOST_OUT_IF="$cand"
            break
        fi
    done
fi

if [[ -z "${HOST_OUT_IF}" ]]; then
    echo "ERROR: could not detect host outbound interface. Exiting."
    exit 1
fi

echo "Host outbound interface detected: ${HOST_OUT_IF}"

# ================================
# BUILD IPTABLES RULES FROM SCRATCH
# ================================
echo "[6] Building iptables rules..."

# Set default policies
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

# Allow established/related connections in FORWARD
iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# Allow forwarding from LXC subnet to anywhere
iptables -A FORWARD -s "$LXC_SUBNET" -j ACCEPT

# Allow forwarding to LXC subnet from anywhere
iptables -A FORWARD -d "$LXC_SUBNET" -j ACCEPT

# POSTROUTING: MASQUERADE for entire LXC subnet going out
iptables -t nat -A POSTROUTING -s "$LXC_SUBNET" -o "$HOST_OUT_IF" -j MASQUERADE

# PREROUTING: DNAT for port forwarding (exclude traffic from LXC subnet to prevent loopback issues)
iptables -t nat -A PREROUTING ! -s "$LXC_SUBNET" -p tcp --dport $PORT1_HOST -j DNAT --to-destination "$CT_IP:$PORT1_CT"
iptables -t nat -A PREROUTING ! -s "$LXC_SUBNET" -p tcp --dport $PORT2_HOST -j DNAT --to-destination "$CT_IP:$PORT2_CT"
iptables -t nat -A PREROUTING ! -s "$LXC_SUBNET" -p tcp --dport 25 -j DNAT --to-destination "$CT_IP:25"
iptables -t nat -A PREROUTING ! -s "$LXC_SUBNET" -p tcp --dport 587 -j DNAT --to-destination "$CT_IP:587"
iptables -t nat -A PREROUTING ! -s "$LXC_SUBNET" -p tcp --dport 465 -j DNAT --to-destination "$CT_IP:465"

# FORWARD: Allow forwarded traffic to these specific ports
iptables -A FORWARD -p tcp -d "$CT_IP" --dport $PORT1_CT -j ACCEPT
iptables -A FORWARD -p tcp -d "$CT_IP" --dport $PORT2_CT -j ACCEPT
iptables -A FORWARD -p tcp -d "$CT_IP" --dport 25 -j ACCEPT
iptables -A FORWARD -p tcp -d "$CT_IP" --dport 587 -j ACCEPT
iptables -A FORWARD -p tcp -d "$CT_IP" --dport 465 -j ACCEPT

# Hairpin NAT: Allow container to access its own forwarded ports via external IP
iptables -t nat -A POSTROUTING -s "$LXC_SUBNET" -d "$CT_IP" -p tcp --dport $PORT1_CT -j MASQUERADE
iptables -t nat -A POSTROUTING -s "$LXC_SUBNET" -d "$CT_IP" -p tcp --dport $PORT2_CT -j MASQUERADE
iptables -t nat -A POSTROUTING -s "$LXC_SUBNET" -d "$CT_IP" -p tcp --dport 25 -j MASQUERADE
iptables -t nat -A POSTROUTING -s "$LXC_SUBNET" -d "$CT_IP" -p tcp --dport 587 -j MASQUERADE
iptables -t nat -A POSTROUTING -s "$LXC_SUBNET" -d "$CT_IP" -p tcp --dport 465 -j MASQUERADE

# ================================
# SAVE IPTABLES RULES
# ================================
echo "[7] Saving iptables rules to $IPTABLES_RULES_FILE ..."
mkdir -p "$(dirname "$IPTABLES_RULES_FILE")"
iptables-save > "$IPTABLES_RULES_FILE"

# ================================
# INSTALL AUTO-RESTORE LOOP
# ================================
echo "[8] Installing iptables auto-restore loop service..."

cat >/usr/local/bin/iptables-restore-loop.sh <<'EOF'
#!/bin/bash
RULES="/etc/iptables/rules.v4"

while true; do
    # Check if critical NAT rules are missing
    if ! iptables-save -t nat | grep -q "MASQUERADE" || ! iptables-save -t nat | grep -q "DNAT"; then
        echo "[$(date)] NAT rules missing — restoring from $RULES ..."
        if [[ -f "$RULES" ]]; then
            iptables-restore < "$RULES"
        fi
    fi
    sleep 5
done
EOF

chmod +x /usr/local/bin/iptables-restore-loop.sh

cat >/etc/systemd/system/iptables-restore-loop.service <<EOF
[Unit]
Description=Restore iptables rules if they are cleared
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/iptables-restore-loop.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable iptables-restore-loop.service
systemctl start iptables-restore-loop.service

# ================================
# FIX DNS INSIDE CONTAINER
# ================================
echo "[9] Setting DNS inside container..."

# Wait a bit for container to be fully ready
sleep 3

lxc-attach -n "$CT_NAME" -- bash -c "cat > /etc/resolv.conf <<'RES'
nameserver 8.8.8.8
nameserver 1.1.1.1
RES
"

# ================================
# INSTALL TOOLS & RUN INSTALLER INSIDE CONTAINER
# ================================
echo "[10] Installing basic tools inside container and running the remote installer..."

# Update and install tools inside container
lxc-attach -n "$CT_NAME" -- bash -c "apt update -y && DEBIAN_FRONTEND=noninteractive apt install -y curl wget nano telnet ca-certificates"

# Create dir and fetch installer
lxc-attach -n "$CT_NAME" -- bash -c "mkdir -p /opt/install && (wget -O /opt/install/install.sh '$GITHUB_SCRIPT_URL' || curl -fsSL -o /opt/install/install.sh '$GITHUB_SCRIPT_URL' || true)"

# If file exists, chmod + run; otherwise warn
lxc-attach -n "$CT_NAME" -- bash -c 'if [[ -f /opt/install/install.sh ]]; then chmod +x /opt/install/install.sh && /opt/install/install.sh; else echo "WARNING: installer not downloaded inside container (/opt/install/install.sh missing)"; fi'

# ================================
# DONE
# ================================
echo "====================================="
echo " SETUP COMPLETE!"
echo "====================================="
echo "Container: $CT_NAME"
echo "Container IP: $CT_IP"
echo "LXC subnet NATed: $LXC_SUBNET"
echo "Host outbound interface: $HOST_OUT_IF"
echo ""
echo "Forwarded Ports (external → container):"
echo "  $PORT1_HOST → $CT_IP:$PORT1_CT"
echo "  $PORT2_HOST → $CT_IP:$PORT2_CT"
echo "  25 → $CT_IP:25"
echo "  587 → $CT_IP:587"
echo "  465 → $CT_IP:465"
echo ""
echo "Auto-restore service: iptables-restore-loop (enabled)"
echo "Iptables rules saved to: $IPTABLES_RULES_FILE"
echo "====================================="
echo ""
echo "Testing connectivity..."
if lxc-attach -n "$CT_NAME" -- timeout 5 ping -c 2 8.8.8.8 >/dev/null 2>&1; then
    echo "✓ Container can reach internet (ping works)"
else
    echo "✗ WARNING: Container cannot reach internet"
fi

if lxc-attach -n "$CT_NAME" -- timeout 5 curl -s http://google.com >/dev/null 2>&1; then
    echo "✓ Container HTTP works"
else
    echo "✗ WARNING: Container HTTP not working"
fi

echo ""
echo "To test SMTP from inside container:"
echo "  lxc-attach -n $CT_NAME -- telnet gmail-smtp-in.l.google.com 25"
echo ""
echo "To access container shell:"
echo "  lxc-attach -n $CT_NAME"
echo "====================================="
