#!/bin/bash
set -e

###########################################
#  PMTA MULTI-INSTANCE INSTALLER (Ubuntu) #
###########################################

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root."
    exit 1
fi

echo "=== PMTA SECOND INSTANCE INSTALLER ==="

read -p "Instance name (example: pmta2): " instance
read -p "PMTA IP: " pmtaip
read -p "PMTA Hostname: " pmtahost
read -p "PMTA Port (must be unique): " pmtaport

# Directories for this instance
inst_dir="/etc/$instance"
bin_dir="/usr/sbin/$instance"
svc_name="$instance.service"

# Ensure directories exist
mkdir -p "$inst_dir"
mkdir -p "$bin_dir"

echo "[*] Downloading files..."

files=(
    "pmta https://raw.githubusercontent.com/19965/sh2/main/pmta"
    "pmtad https://raw.githubusercontent.com/19965/sh2/main/pmtad"
    "pmtahttpd https://raw.githubusercontent.com/19965/sh2/main/pmtahttpd"
    "pmtasnmpd https://raw.githubusercontent.com/19965/sh2/main/pmtasnmpd"
    "license https://raw.githubusercontent.com/19965/sh2/main/license"
    "config https://raw.githubusercontent.com/19965/sh2/main/config"
    "mykey.$pmtahost.pem https://raw.githubusercontent.com/19965/sh2/main/mykey.6068805.com.pem"
)

for file in "${files[@]}"; do
    name=$(echo $file | awk '{print $1}')
    url=$(echo $file | awk '{print $2}')
    wget -q -O "/tmp/$name" "$url"
done

echo "[*] Copying instance files..."

cp /tmp/license "$inst_dir/"
cp /tmp/config "$inst_dir/"
cp "/tmp/mykey.$pmtahost.pem" "$inst_dir/"

# Copy binaries under unique folder
cp /tmp/pmta "$bin_dir/"
cp /tmp/pmtad "$bin_dir/"
cp /tmp/pmtahttpd "$bin_dir/"
cp /tmp/pmtasnmpd "$bin_dir/"

chmod +x "$bin_dir/"*

echo "[*] Updating configuration..."

sed -i "s/QQQipQQQ/$pmtaip/g" "$inst_dir/config"
sed -i "s/QQQhostnameQQQ/$pmtahost/g" "$inst_dir/config"
sed -i "s/QQQportQQQ/$pmtaport/g" "$inst_dir/config"

# Add unique HTTP/SNMP port


##################################
# SYSTEMD SERVICE FOR INSTANCE   #
##################################

echo "[*] Creating systemd service: $svc_name"

cat > "/etc/systemd/system/$svc_name" <<EOF
[Unit]
Description=PowerMTA Instance $instance
After=network.target

[Service]
Type=forking
ExecStart=$bin_dir/pmtad -c $inst_dir/config
ExecStop=$bin_dir/pmtad shutdown
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$svc_name"
systemctl restart "$svc_name"

echo "============================================="
echo "PMTA instance installed successfully!"
echo "Instance name: $instance"
echo "Config dir: $inst_dir"
echo "Binary dir: $bin_dir"
echo "Service name: $svc_name"
echo "Hostname: $pmtahost"
echo "SMTP Port: $pmtaport"
echo "Login: admin / admin1111"
echo "============================================="
