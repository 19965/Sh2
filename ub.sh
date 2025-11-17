#!/bin/bash
set -e

echo "=== PowerMTA 4.0r6 MULTI INSTANCE CLONE INSTALLER ==="

if [ "$(id -u)" != "0" ]; then
    echo "Run this script as ROOT."
    exit 1
fi

read -p "Instance name (example: pmta2): " INSTANCE
read -p "New SMTP port (unique): " SMTP_PORT
read -p "New HTTP port (unique): " HTTP_PORT
read -p "New hostname: " HOST
read -p "New IP: " IP

# Paths for the new instance
ETC_NEW="/etc/$INSTANCE"
LOG_NEW="/var/log/$INSTANCE"
SPOOL_NEW="/var/spool/$INSTANCE"
BIN_NEW="/usr/sbin/$INSTANCE"
RUN_NEW="/var/run/$INSTANCE"

echo "[*] Creating directory structure..."
mkdir -p $BIN_NEW
mkdir -p $RUN_NEW

echo "[*] Cloning PMTA configuration..."
cp -r /etc/pmta $ETC_NEW
cp -r /var/log/pmta $LOG_NEW
cp -r /var/spool/pmta $SPOOL_NEW

echo "[*] Cloning binaries..."
cp /usr/sbin/pmtad $BIN_NEW/
cp /usr/sbin/pmta $BIN_NEW/
cp /usr/sbin/pmtahttpd $BIN_NEW/
cp /usr/sbin/pmtasnmpd $BIN_NEW/

chmod +x $BIN_NEW/*

echo "[*] Fixing internal paths in config..."
sed -i "s#/etc/pmta#$ETC_NEW#g" $ETC_NEW/config
sed -i "s#/var/log/pmta#$LOG_NEW#g" $ETC_NEW/config
sed -i "s#/var/spool/pmta#$SPOOL_NEW#g" $ETC_NEW/config

echo "[*] Updating listener ports..."
sed -i "s/smtp-listener .*/smtp-listener $IP:$SMTP_PORT/" $ETC_NEW/config

echo "[*] Updating hostname..."
sed -i "s/host-name .*/host-name $HOST/" $ETC_NEW/config
sed -i "s/postmaster .*/postmaster you@$HOST/" $ETC_NEW/config

echo "[*] Updating HTTP port..."
if ! grep -q "http-mgmt-port" $ETC_NEW/config; then
    echo "http-mgmt-port $HTTP_PORT" >> $ETC_NEW/config
else
    sed -i "s/http-mgmt-port .*/http-mgmt-port $HTTP_PORT/" $ETC_NEW/config
fi

echo "[*] Creating systemd service..."

SERVICE_FILE="/etc/systemd/system/$INSTANCE.service"

cat > $SERVICE_FILE <<EOF
[Unit]
Description=PowerMTA Instance $INSTANCE
After=network.target

[Service]
Type=forking
WorkingDirectory=$ETC_NEW
ExecStart=$BIN_NEW/pmtad
ExecStop=$BIN_NEW/pmtad shutdown
PIDFile=$RUN_NEW/pid
Restart=always

[Install]
WantedBy=multi-user.target
EOF

echo "[*] Reloading systemd..."
systemctl daemon-reload

echo "[*] Enabling service..."
systemctl enable $INSTANCE

echo "[*] Starting instance..."
systemctl start $INSTANCE

echo "==============================================="
echo "PowerMTA clone instance installed successfully!"
echo "Instance name:     $INSTANCE"
echo "Config directory:  $ETC_NEW"
echo "Log directory:     $LOG_NEW"
echo "Spool directory:   $SPOOL_NEW"
echo "Binary directory:  $BIN_NEW"
echo "SMTP Port:         $SMTP_PORT"
echo "HTTP Port:         $HTTP_PORT"
echo "==============================================="
echo "Run: systemctl status $INSTANCE"
echo "==============================================="
