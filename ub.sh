#!/bin/bash

# Exit on any error
set -e 

# Validate user privileges
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Exiting."
    exit 1
fi

# Prompt for instance-specific inputs
read -p "Enter instance name (e.g., instance1, instance2): " instance_name
read -p "Your PMTA IP: " pmtaip
read -p "Your PMTA hostname: " pmtahostname
read -p "Your PMTA port: " pmtaport

# Validate instance name
if [[ ! $instance_name =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "Invalid instance name. Only letters, numbers, hyphens and underscores allowed. Exiting."
    exit 1
fi

# Validate IP address format
if [[ ! $pmtaip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Invalid IP address format. Exiting."
    exit 1
fi

# Instance-specific variables
instance_dir="/etc/pmta_$instance_name"
service_name="pmta_$instance_name"
log_dir="/var/log/pmta_$instance_name"
user_name="pmta_$instance_name"
group_name="pmta_$instance_name"

# Files to download
files=(
    "powermta_4.0r6-201204021810_amd64.deb https://raw.githubusercontent.com/19965/sh/main/powermta_4.0r6-201204021810_amd64.deb"
    "pmta https://raw.githubusercontent.com/19965/sh/main/pmta"
    "pmtad https://raw.githubusercontent.com/19965/sh/main/pmtad"
    "pmtahttpd https://raw.githubusercontent.com/19965/sh/main/pmtahttpd"
    "pmtasnmpd https://raw.githubusercontent.com/19965/sh/main/pmtasnmpd"
    "license https://raw.githubusercontent.com/19965/sh/main/license"
    "config https://raw.githubusercontent.com/19965/sh/main/config"
    "mykey.${pmtahostname}.pem https://raw.githubusercontent.com/19965/sh/main/mykey.6068805.com.pem"
)

# Download files
for file in "${files[@]}"; do
    filename=$(echo $file | awk '{print $1}')
    url=$(echo $file | awk '{print $2}')
    echo "Downloading $filename..."
    wget -q -O "$filename" "$url" || { echo "Failed to download $filename. Exiting."; exit 1; }
done

# Create instance-specific user and group
echo "Creating user and group for instance $instance_name..."
if ! id "$user_name" &>/dev/null; then
    # Create pmta group
    if ! getent group "$group_name" >/dev/null; then
        groupadd --system "$group_name"
    fi
    # Create pmta user
    useradd --system --no-create-home --home-dir "$instance_dir" --shell /bin/false -g "$group_name" "$user_name"
    echo "Created user $user_name and group $group_name."
else
    echo "User $user_name already exists."
fi

# Install PowerMTA using dpkg (only if not already installed system-wide)
if ! dpkg -l | grep -q powermta; then
    echo "Installing PowerMTA..."
    dpkg -i powermta_4.0r6-201204021810_amd64.deb || { 
        echo "Failed to install PowerMTA. Attempting to fix dependencies..."; 
        apt-get update && apt-get install -f -y || { echo "Failed to fix dependencies. Exiting."; exit 1; }
    }
else
    echo "PowerMTA already installed system-wide, skipping installation."
fi

# Stop existing instance service if running
echo "Stopping existing service for instance $instance_name..."
systemctl stop "$service_name" 2>/dev/null || echo "Service $service_name not running, continuing setup."

# Create instance directory
echo "Creating instance directory $instance_dir..."
mkdir -p "$instance_dir"

# Backup existing instance configurations
backup_dir="${instance_dir}_backup_$(date +%Y%m%d%H%M%S)"
if [ -d "$instance_dir" ] && [ "$(ls -A $instance_dir)" ]; then
    echo "Backing up existing configuration to $backup_dir..."
    mkdir -p "$backup_dir"
    cp -r "$instance_dir"/* "$backup_dir/" 2>/dev/null || echo "No existing configuration to backup."
fi

# Copy files to instance-specific locations
echo "Copying files to instance directory..."
\cp -f license "$instance_dir/"
\cp -f config "$instance_dir/"
\cp -f "mykey.$pmtahostname.pem" "$instance_dir/mykey.$pmtahostname.pem"

# Copy binaries (these will be shared across instances)
\cp -f pmta /usr/sbin/
\cp -f pmtad /usr/sbin/
\cp -f pmtahttpd /usr/sbin/
\cp -f pmtasnmpd /usr/sbin/

# Update configuration with provided inputs
echo "Updating configurations for instance $instance_name..."
sed -i "s/QQQipQQQ/$pmtaip/g" "$instance_dir/config"
sed -i "s/QQQhostnameQQQ/$pmtahostname/g" "$instance_dir/config"
sed -i "s/QQQportQQQ/$pmtaport/g" "$instance_dir/config"

# Update configuration to use instance-specific paths
sed -i "s|/var/log/pmta|$log_dir|g" "$instance_dir/config"
sed -i "s|/etc/pmta|$instance_dir|g" "$instance_dir/config"

# Create log directory
mkdir -p "$log_dir"
chown "$user_name:$group_name" "$log_dir"

# Set ownership and permissions for instance
echo "Setting permissions..."
chown "$user_name:$group_name" /usr/sbin/pmtahttpd
chown -R "$user_name:$group_name" "$instance_dir/"
chmod 755 /usr/sbin/pmtahttpd
chmod 600 "$instance_dir/license"
chmod 600 "$instance_dir/mykey.$pmtahostname.pem"

# Create instance-specific systemd service file
echo "Creating systemd service for instance $instance_name..."
cat > "/etc/systemd/system/$service_name.service" << EOF
[Unit]
Description=PowerMTA Daemon - Instance $instance_name
After=network.target

[Service]
Type=forking
User=$user_name
Group=$group_name
ExecStart=/usr/sbin/pmtad -c $instance_dir -l $log_dir
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

# Create instance-specific HTTP service if needed
if [ -f /usr/sbin/pmtahttpd ]; then
    cat > "/etc/systemd/system/${service_name}_http.service" << EOF
[Unit]
Description=PowerMTA HTTP Daemon - Instance $instance_name
After=network.target $service_name.service

[Service]
Type=simple
User=$user_name
Group=$group_name
ExecStart=/usr/sbin/pmtahttpd -c $instance_dir -l $log_dir
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
fi

# Reload systemd and start services
echo "Starting services for instance $instance_name..."
systemctl daemon-reload

systemctl enable "$service_name.service"
systemctl start "$service_name.service"

if [ -f "/etc/systemd/system/${service_name}_http.service" ]; then
    systemctl enable "${service_name}_http.service"
    systemctl start "${service_name}_http.service"
fi

# Verify services are running
echo "Checking service status..."
if systemctl is-active --quiet "$service_name.service"; then
    echo "✓ PMTA service for instance $instance_name is running"
else
    echo "✗ PMTA service for instance $instance_name failed to start"
    systemctl status "$service_name.service"
fi

if [ -f "/etc/systemd/system/${service_name}_http.service" ] && systemctl is-active --quiet "${service_name}_http.service"; then
    echo "✓ PMTA HTTP service for instance $instance_name is running"
fi

# Completion message
echo ""
echo "PMTA installation for instance '$instance_name' successful!"
echo "============================================="
echo "Instance name: $instance_name"
echo "PMTA host: $pmtahostname"
echo "PMTA IP: $pmtaip"
echo "PMTA port: $pmtaport"
echo "Configuration directory: $instance_dir"
echo "Log directory: $log_dir"
echo "Service name: $service_name"
echo "PMTA mail account: support@$pmtahostname"
echo "PMTA username: admin"
echo "PMTA password: admin1111"
echo ""
echo "Management commands:"
echo "  systemctl start $service_name"
echo "  systemctl stop $service_name"
echo "  systemctl status $service_name"
if [ -f "/etc/systemd/system/${service_name}_http.service" ]; then
    echo "  systemctl start ${service_name}_http"
    echo "  systemctl stop ${service_name}_http"
fi
echo "============================================="
