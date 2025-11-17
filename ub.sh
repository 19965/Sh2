#!/bin/bash
set -e

echo "=== PowerMTA OFFICIAL MULTI INSTANCE INSTALLER ==="

if [ "$(id -u)" != "0" ]; then
    echo "Run as root."
    exit 1
fi

read -p "Instance name (ex: pmta2): " INSTANCE
read -p "Instance IP: " IP
read -p "Hostname: " HOST
read -p "SMTP Port (unique): " SMTP_PORT
read -p "HTTP Port (unique): " HTTP_PORT

BASE="/opt/$INSTANCE"
BIN="$BASE/bin"
CFG="$BASE/config"
LOG="$BASE/log"
SPOOL="$BASE/spool"
RUN="$BASE/run"

echo "[*] Creating directory structure recommended by PMTA User Guide..."
mkdir -p $BIN $CFG $LOG $SPOOL $RUN

echo "[*] Downloading PMTA binaries and config/templates..."
wget -q -O $BIN/pmta https://raw.githubusercontent.com/19965/sh/main/pmta
wget -q -O $BIN/pmtad https://raw.githubusercontent.com/19965/sh/main/pmtad
wget -q -O $BIN/pmtahttpd https://raw.githubusercontent.com/19965/sh/main/pmtahttpd
wget -q -O $CFG/license https://raw.githubusercontent.com/19965/sh/main/license
wget -q -O $CFG/mykey.$HOST.pem https://raw.githubusercontent.com/19965/sh/main/mykey.6068805.com.pem
wget -q -O $CFG/config.raw https://raw.githubusercontent.com/19965/sh/main/config

chmod +x $BIN/*

echo "[*] Building PMTA config file according to User Guide rules..."
sed "s/QQQipQQQ/$IP/g;
     s/QQQhostnameQQQ/$HOST/g;
     s/QQQportQQQ/$SMTP_PORT/g" $CFG/config.raw > $CFG/config

# Replace all hardcoded paths with instance paths
sed -i "s|/etc/pmta|$CFG|g" $CFG/config
sed -i "s|/var/log/pmta|$LOG|g" $CFG/config
sed -i "s|/var/spool/pmta|$SPOOL|g" $CFG/config

echo "http-mgmt-port $HTTP_PORT" >> $CFG/config

echo "log-file $LOG/pmta.log" >> $CFG/config
echo "<acct-file $LOG/acct.csv>" >> $CFG/config
echo "</acct-file>" >> $CFG/config

echo "<spool $SPOOL>" >> $CFG/config
echo "</spool>" >> $CFG/config

####################################
# SYSTEMD SERVICE PER USER GUIDE
####################################

SERVICE_FILE="/etc/systemd/system/$INSTANCE.service"

echo "[*] Creating official systemd unit: $SERVICE_FILE"

cat > $SERVICE_FILE <<EOF
[Unit]
Description=PowerMTA Instance $INSTANCE
After=network.target

[Service]
Type=forking
ExecStart=$BIN/pmtad -c $CFG/config -pid $RUN/pid
ExecStop=$BIN/pmtad shutdown
PIDFile=$RUN/pid
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable $INSTANCE
systemctl start $INSTANCE

echo "=============================================="
echo "PowerMTA instance installed successfully!"
echo "Instance: $INSTANCE"
echo "Config:   $CFG/config"
echo "Bins:     $BIN"
echo "Logs:     $LOG"
echo "Spool:    $SPOOL"
echo "RUN:      $RUN"
echo "HTTP:     $HTTP_PORT"
echo "SMTP:     $SMTP_PORT"
echo "=============================================="
