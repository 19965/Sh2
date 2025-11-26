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
LXC_ROOT="/var/lib/lxc"   # default; used only for a fallback
# LXC's default private bridge network is usually 10.0.3.0/24 for the "download" template.
# We'll detect the container IP at runtime and also NAT the whole LXC subnet.

echo "Starting LXC setup and container creation..."

# ================================
# INSTALL LXC & DEPENDENCIES
# ================================
echo "[1] Installing LXC & tools..."
apt update -y
DEBIAN_FRONTEND=noninteractive apt install -y lxc lxc-templates bridge-utils debootstrap iptables-persistent curl wget

# ensure sysctl allows forwarding
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
# wait for container to have an IP
echo "[5] Waiting for container to obtain an IP..."
for i in {1..20}; do
  CT_IP=$(lxc-info -n "$CT_NAME" -iH || true)
  if [[ -n "$CT_IP" && "$CT_IP" != " " && "$CT_IP" != "127.0.0.1" ]]; then
    break
  fi
  sleep 1
done

if [[ -z "${CT_IP:-}" ]]; then
  echo "ERROR: could not detect container IP. Check 'lxc-info -n $CT_NAME -iH'. Exiting."
  exit 1
fi

echo "Container IP = $CT_IP"

# detect LXC bridge subnet (best-effort)
# common default: lxcbr0 with 10.0.3.1/24, so subnet 10.0.3.0/24
LXC_BRIDGE_IF="lxcbr0"
if ip addr show dev "${LXC_BRIDGE_IF}" >/dev/null 2>&1; then
  LXC_SUBNET=$(ip -o -f inet addr show dev "${LXC_BRIDGE_IF}" | awk '{print $4}' | head -n1)
fi
# fallback: infer from container IP
if [[ -z "${LXC_SUBNET:-}" ]]; then
  # use /24 of container IP
  LXC_SUBNET="${CT_IP%.*}.0/24"
fi

echo "Using LXC subnet for NAT: $LXC_SUBNET"

# ================================
# DETECT HOST DEFAULT OUTBOUND INTERFACE (for MASQUERADE - best-effort)
# ================================
# This tries to find the interface used for external traffic (works on AWS)
HOST_OUT_IF="$(ip route get 8.8.8.8 2>/dev/null | awk -- '{for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1); exit}}}')"
if [[ -z "${HOST_OUT_IF}" ]]; then
  # fallback common names
  for cand in eth0 ens5 ens3; do
    if ip link show "$cand" >/dev/null 2>&1; then
      HOST_OUT_IF="$cand"
      break
    fi
  done
fi
if [[ -z "${HOST_OUT_IF}" ]]; then
  echo "Warning: could not reliably detect host outbound interface. MASQUERADE will not restrict by -o interface."
fi
echo "Host outbound interface detected: ${HOST_OUT_IF:-(none)}"

# ================================
# ADD IPTABLES NAT / FORWARDING RULES (idempotent)
# ================================
echo "[6] Installing iptables rules (NAT + forwarding + DNAT ports)..."

# helper to add rule only if missing
ip_add_rule() {
  # $1: full rule (iptables arguments)
  if ! iptables ${@:1} -C "${@:2}" 2>/dev/null; then
    # we can't easily use -C with arbitrary args, so use a safer approach below
    :
  fi
}

# To be simple and idempotent: delete matching previous rules we create, then add clean ones.
# Delete any existing rules we inserted earlier for these DNAT ports (best-effort).
iptables -t nat -D PREROUTING -p tcp --dport $PORT1_HOST -j DNAT --to-destination "$CT_IP:$PORT1_CT" 2>/dev/null || true
iptables -D FORWARD -p tcp -d "$CT_IP" --dport $PORT1_CT -j ACCEPT 2>/dev/null || true

iptables -t nat -D PREROUTING -p tcp --dport $PORT2_HOST -j DNAT --to-destination "$CT_IP:$PORT2_CT" 2>/dev/null || true
iptables -D FORWARD -p tcp -d "$CT_IP" --dport $PORT2_CT -j ACCEPT 2>/dev/null || true

iptables -t nat -D PREROUTING -p tcp --dport 25 -j DNAT --to-destination "$CT_IP:25" 2>/dev/null || true
iptables -D FORWARD -p tcp -d "$CT_IP" --dport 25 -j ACCEPT 2>/dev/null || true

iptables -t nat -D PREROUTING -p tcp --dport 587 -j DNAT --to-destination "$CT_IP:587" 2>/dev/null || true
iptables -D FORWARD -p tcp -d "$CT_IP" --dport 587 -j ACCEPT 2>/dev/null || true

iptables -t nat -D PREROUTING -p tcp --dport 465 -j DNAT --to-destination "$CT_IP:465" 2>/dev/null || true
iptables -D FORWARD -p tcp -d "$CT_IP" --dport 465 -j ACCEPT 2>/dev/null || true

# remove any older POSTROUTING MASQUERADE for this subnet (best-effort)
iptables -t nat -D POSTROUTING -s "$LXC_SUBNET" -j MASQUERADE 2>/dev/null || true

# Add rules
# Allow forwarding RELATED,ESTABLISHED first
iptables -C FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# Forward between host and LXC subnet
iptables -C FORWARD -s "$LXC_SUBNET" -j ACCEPT 2>/dev/null || iptables -A FORWARD -s "$LXC_SUBNET" -j ACCEPT
iptables -C FORWARD -d "$LXC_SUBNET" -j ACCEPT 2>/dev/null || iptables -A FORWARD -d "$LXC_SUBNET" -j ACCEPT

# POSTROUTING MASQUERADE for entire LXC subnet (robust on AWS)
if [[ -n "${HOST_OUT_IF}" ]]; then
  # prefer restricting by outbound interface
  iptables -t nat -C POSTROUTING -s "$LXC_SUBNET" -o "$HOST_OUT_IF" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "$LXC_SUBNET" -o "$HOST_OUT_IF" -j MASQUERADE
else
  iptables -t nat -C POSTROUTING -s "$LXC_SUBNET" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "$LXC_SUBNET" -j MASQUERADE
fi

# DNAT port-forwarding
iptables -t nat -A PREROUTING -p tcp --dport $PORT1_HOST -j DNAT --to-destination "$CT_IP:$PORT1_CT"
iptables -A FORWARD -p tcp -d "$CT_IP" --dport $PORT1_CT -j ACCEPT

iptables -t nat -A PREROUTING -p tcp --dport $PORT2_HOST -j DNAT --to-destination "$CT_IP:$PORT2_CT"
iptables -A FORWARD -p tcp -d "$CT_IP" --dport $PORT2_CT -j ACCEPT

iptables -t nat -A PREROUTING -p tcp --dport 25 -j DNAT --to-destination "$CT_IP:25"
iptables -A FORWARD -p tcp -d "$CT_IP" --dport 25 -j ACCEPT

iptables -t nat -A PREROUTING -p tcp --dport 587 -j DNAT --to-destination "$CT_IP:587"
iptables -A FORWARD -p tcp -d "$CT_IP" --dport 587 -j ACCEPT

iptables -t nat -A PREROUTING -p tcp --dport 465 -j DNAT --to-destination "$CT_IP:465"
iptables -A FORWARD -p tcp -d "$CT_IP" --dport 465 -j ACCEPT

# ================================
# SAVE IPTABLES RULES (persistent)
# ================================
echo "[7] Saving iptables rules to $IPTABLES_RULES_FILE ..."
mkdir -p "$(dirname "$IPTABLES_RULES_FILE")"
iptables-save > "$IPTABLES_RULES_FILE"

# also save with iptables-persistent format (it uses same file)
# package iptables-persistent reads /etc/iptables/rules.v4 on boot

# ================================
# INSTALL AUTO-RESTORE LOOP (improved)
# ================================
echo "[8] Installing iptables auto-restore loop service..."

cat >/usr/local/bin/iptables-restore-loop.sh <<'EOF'
#!/bin/bash
RULES="/etc/iptables/rules.v4"
# keep the loop modest to avoid CPU churn
while true; do
  if ! iptables-save | grep -q "MASQUERADE" || ! iptables-save -t nat | grep -q "DNAT"; then
    echo "[*] NAT rules missing — restoring from $RULES ..."
    if [[ -f "$RULES" ]]; then
      iptables-restore < "$RULES"
    fi
  fi
  sleep 3
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
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable iptables-restore-loop.service
systemctl restart iptables-restore-loop.service

# ================================
# FIX DNS INSIDE CONTAINER (reliable)
# ================================
echo "[9] Setting DNS inside container..."
# Use lxc-attach to write resolv.conf in the container (handles mounts correctly)
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

# create dir and fetch installer
lxc-attach -n "$CT_NAME" -- bash -c "mkdir -p /opt/install && wget -O /opt/install/install.sh '$GITHUB_SCRIPT_URL' || curl -fsSL -o /opt/install/install.sh '$GITHUB_SCRIPT_URL' || true"

# if file exists, chmod + run; otherwise warn
lxc-attach -n "$CT_NAME" -- bash -c 'if [[ -f /opt/install/install.sh ]]; then chmod +x /opt/install/install.sh && /opt/install/install.sh; else echo "WARNING: installer not downloaded inside container (/opt/install/install.sh missing)"; fi'

# ================================
# DONE
# ================================
echo "====================================="
echo " DONE!"
echo "====================================="
echo "Container: $CT_NAME"
echo "Container IP: $CT_IP"
echo "LXC subnet NATed: $LXC_SUBNET"
echo "Forwarded Ports:"
echo "  $PORT1_HOST -> $PORT1_CT"
echo "  $PORT2_HOST -> $PORT2_CT"
echo "  25 -> 25"
echo "  587 -> 587"
echo "  465 -> 465"
echo "Auto-restore service installed: iptables-restore-loop"
echo "Iptables rules saved to: $IPTABLES_RULES_FILE"
echo "====================================="
