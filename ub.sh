#!/bin/bash
set -e

echo "=== PowerMTA SECOND INSTANCE INSTALLER (pmta2) ==="

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this script as ROOT."
    exit 1
fi

# Collect instance info
read -p "PMTA2 IP: " IP
read -p "PMTA2 hostname: " HOST
read -p "PMTA2 SMTP port (example: 2526): " SMTP_PORT
read -p "PMTA2 HTTP port (example: 2726): " HTTP_PORT

### SECOND INSTANCE PATHS
INSTDIR="/opt/pmta2"
CONFDIR="/etc/pmta2"
LOGDIR="/var/log/pmta2"
SPOOLDIR="/var/spool/pmta2"
PIDFILE="/var/run/pmta2.pid"

echo "[*] Creating directories..."
mkdir -p $INSTDIR/bin
mkdir -p $CONFDIR
mkdir -p $LOGDIR
mkdir -p $SPOOLDIR
mkdir -p /var/run

### COPY PMTA BINARIES FROM ORIGINAL INSTALL
echo "[*] Copying PMTA binaries..."
cp /usr/sbin/pmtad $INSTDIR/bin/
cp /usr/sbin/pmta $INSTDIR/bin/
cp /usr/sbin/pmtahttpd $INSTDIR/bin/
cp /usr/sbin/pmtasnmpd $INSTDIR/bin/

chmod +x $INSTDIR/bin/*

### COPY LICENSE & DKIM KEY FROM PMTA1
echo "[*] Copying license and DKIM key..."
cp /etc/pmta/license $CONFDIR/license
cp /etc/pmta/mykey.*.pem $CONFDIR/mykey.pem

### CREATE CONFIG FILE
echo "[*] Creating configuration..."
cat > $CONFDIR/config <<EOF
postmaster you@$HOST
host-name $HOST

smtp-listener $IP:$SMTP_PORT

domain-key mykey, $HOST, $CONFDIR/mykey.pem

log-file $LOGDIR/pmta.log

<spool $SPOOLDIR>
    deliver-only no
</spool>

http-mgmt-port $HTTP_PORT

http-access 127.0.0.1 monitor
http-access ::1 monitor
http-access $IP admin

pid-file $PIDFILE
EOF

### CREATE SYSTEMD SERVICE
echo "[*] Creating systemd service..."

cat > /etc/systemd/system/pmta2.service <<EOF
[Unit]
Description=PowerMTA Second Instance (pmta2)
After=network.target

[Service]
Type=forking
ExecStart=$INSTDIR/bin/pmtad --config=$CONFDIR/config --pid-file=$PIDFILE
ExecStop=$INSTDIR/bin/pmtad shutdown
PIDFile=$PIDFILE
Restart=always

[Install]
WantedBy=multi-user.target
EOF

### Final steps
echo "[*] Reloading systemd..."
systemctl daemon-reload

echo "[*] Enabling pmta2..."
systemctl enable pmta2

echo "[*] Starting pmta2..."
systemctl restart pmta2 || {
    echo "Startup failed. Check: journalctl -u pmta2 -xe"
    exit 1
}

echo "===================================="
echo " PMTA2 INSTALLED SUCCESSFULLY! "
echo "===================================="
echo "SMTP Listener: $IP:$SMTP_PORT"
echo "HTTP Admin:    $IP:$HTTP_PORT"
echo "Config:        $CONFDIR/config"
echo "Logs:          $LOGDIR"
echo "Spool:         $SPOOLDIR"
echo "Binary path:   $INSTDIR/bin"
echo "PID File:      $PIDFILE"
echo "===================================="
