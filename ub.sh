#!/bin/bash

# Exit on any error
set -e 

# Validate user privileges
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Exiting."
    exit 1
fi

# Prompt for user inputs
read -p "Your PMTA IP: " pmtaip
read -p "Your PMTA hostname: " pmtahostname
read -p "Your PMTA port: " pmtaport

# Validate IP address format
if [[ ! $pmtaip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Invalid IP address format. Exiting."
    exit 1
fi

# Files to download
files=(
    "powermta_4.0r6-201204021810_amd64.deb https://raw.githubusercontent.com/19965/sh2/main/powermta_4.0r6-201204021810_amd64.deb"
    "pmta https://raw.githubusercontent.com/19965/sh2/main/pmta"
    "pmtad https://raw.githubusercontent.com/19965/sh2/main/pmtad"
    "pmtahttpd https://raw.githubusercontent.com/19965/sh2/main/pmtahttpd"
    "pmtasnmpd https://raw.githubusercontent.com/19965/sh2/main/pmtasnmpd"
    "license https://raw.githubusercontent.com/19965/sh2/main/license"
    "config https://raw.githubusercontent.com/19965/sh2/main/config"
    "mykey.${pmtahostname}.pem https://raw.githubusercontent.com/19965/sh2/main/mykey.6068805.com.pem"
)

# Download files
for file in "${files[@]}"; do
    filename=$(echo $file | awk '{print $1}')
    url=$(echo $file | awk '{print $2}')
    echo "Downloading $filename..."
    wget -q -O "$filename" "$url" || { echo "Failed to download $filename. Exiting."; exit 1; }
done

# Create pmta user and group if they don't exist
echo "Creating pmta user and group..."
if ! id "pmta" &>/dev/null; then
    # Create pmta group
    if ! getent group pmta >/dev/null; then
        groupadd --system pmta
    fi
    # Create pmta user
    useradd --system --no-create-home --home-dir /etc/pmta --shell /bin/false -g pmta pmta
    echo "Created pmta user and group."
else
    echo "pmta user already exists."
fi

# Install PowerMTA using dpkg
echo "Installing PowerMTA..."
dpkg -i powermta_4.0r6-201204021810_amd64.deb || { 
    echo "Failed to install PowerMTA. Attempting to fix dependencies..."; 
    apt-get update && apt-get install -f -y || { echo "Failed to fix dependencies. Exiting."; exit 1; }
}

# Stop PMTA service if running
echo "Stopping PMTA service..."
systemctl stop pmta 2>/dev/null || service pmta stop 2>/dev/null || echo "PMTA service not running, continuing setup."

# Backup existing configurations
backup_dir="/etc/pmta_backup_$(date +%Y%m%d%H%M%S)"
mkdir -p "$backup_dir"
if [ -d "/etc/pmta" ]; then
    echo "Backing up existing configuration to $backup_dir..."
    cp -r /etc/pmta/* "$backup_dir/" 2>/dev/null || echo "No existing configuration to backup."
fi

# Copy files to appropriate locations
echo "Copying new files..."
\cp -f license /etc/pmta/
\cp -f config /etc/pmta/
\cp -f mykey.$pmtahostname.pem "/etc/pmta/mykey.$pmtahostname.pem"
\cp -f pmta /usr/sbin/
\cp -f pmtad /usr/sbin/
\cp -f pmtahttpd /usr/sbin/
\cp -f pmtasnmpd /usr/sbin/

# Update configuration with provided inputs
echo "Updating configurations..."
sed -i "s/QQQipQQQ/$pmtaip/g" `grep "QQQipQQQ" -rl /etc/pmta/ 2>/dev/null || echo ""`
sed -i "s/QQQhostnameQQQ/$pmtahostname/g" `grep "QQQhostnameQQQ" -rl /etc/pmta/ 2>/dev/null || echo ""`
sed -i "s/QQQportQQQ/$pmtaport/g" `grep "QQQportQQQ" -rl /etc/pmta/ 2>/dev/null || echo ""`

# Set ownership and permissions for pmtahttpd and configuration directory
echo "Setting permissions..."
chown pmta:pmta /usr/sbin/pmtahttpd
chown -R pmta:pmta /etc/pmta/ 2>/dev/null || echo "Could not change ownership of /etc/pmta"
chmod 755 /usr/sbin/pmtahttpd
chmod 600 /etc/pmta/license 2>/dev/null || echo "Could not set license permissions"
chmod 600 /etc/pmta/mykey.$pmtahostname.pem 2>/dev/null || echo "Could not set key permissions"

# Restart PMTA service
echo "Restarting PMTA service..."
systemctl daemon-reload 2>/dev/null || true
systemctl restart pmta 2>/dev/null || service pmta restart 2>/dev/null || { 
    echo "Failed to restart PMTA service. Please check logs."; 
    exit 1; 
}

# Enable PMTA to start on boot
systemctl enable pmta 2>/dev/null || true

# Verify pmta user ownership
echo "Verifying pmta user configuration..."
if id pmta &>/dev/null; then
    echo "pmta user created successfully: $(id pmta)"
else
    echo "Warning: pmta user may not exist properly"
fi
# Restart PMTA services
echo "Restarting PMTA services..."
systemctl daemon-reload 2>/dev/null || true

# Restart both PMTA and PMTA HTTP services
systemctl restart pmta 2>/dev/null || service pmta restart 2>/dev/null || { 
    echo "Failed to restart PMTA service. Please check logs."; 
    exit 1; 
}

# Restart PMTA HTTP service if it exists
if systemctl list-unit-files | grep -q pmtahttp; then
    systemctl restart pmtahttp 2>/dev/null || echo "PMTA HTTP service not available or failed to restart"
else
    echo "PMTA HTTP service not found, skipping restart"
fi

# Enable PMTA to start on boot
systemctl enable pmta 2>/dev/null || true
# Completion message
echo "PMTA installation successful!"
echo "============================================="
echo "PMTA host: $pmtahostname"
echo "PMTA port: $pmtaport"
echo "PMTA mail account: support@$pmtahostname"
echo "PMTA username: admin"
echo "PMTA password: admin1111"
echo "============================================="
