#!/bin/bash
set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root"
    exit 1
fi

echo "Second PMTA Instance Installer"
read -p "PMTA2 IP: " pmtaip
read -p "PMTA2 hostname: " hostname
read -p "PMTA2 SMTP PORT: " smtpport
read -p "PMTA2 Web Port: " webport

### DIRECTORIES FOR SECOND INSTANCE
INSTDIR="/opt/pmta2"
CONFDIR="/etc/pmta2"
LOGDIR="/var/log/pmta2"
SPOOLDIR="/var/spool/pmta2"
PIDFILE="/var/run/pmta2.pid"

### CREATE DIRECTORIES
mkdir -p $INSTDIR/bin
mkdir -p $CONFDIR
mkdir -p $LOGDIR
mkdir -p $SPOOLDIR

### COPY ORIGINAL PMTA BINARIES TO PMTA2
cp /usr/sbin/pmta $INSTDIR/bin/
cp /usr/sbin/pmtad $INSTDIR/bin/
cp /usr/sbin/pmtahttpd $INSTDIR/bin/

### CREATE NEW CONFIG
cat > $CONFDIR/config <<EOF
postmaster you@$hostname
host-name $hostname

smtp-listener $pmtaip:$smtpport

domain-key mykey, $hostname, $CONFDIR/mykey.pem

log-file $LOGDIR/pmta.log

<spool $SPOOLDIR>
    deliver-only no
</spool>

http-mgmt-port $webport
http-access 127.0.0.1 monitor
http-access ::1 monitor
EOF

### COPY LICENSE + KEY
cp license $CONFDIR/license
cp mykey.$hostname.pem $CONFDIR/mykey.pem

### CREATE SYSTEMD SERVICE FILE
cat > /etc/systemd/system/pmta2.service <<EOF
[Unit]
Description=PowerMTA Instance 2
After=network.target

[Service]
ExecStart=$INSTDIR/bin/pmtad --config=$CONFDIR/config --pid-file=$PIDFILE
PIDFile=$PIDFILE
Restart=always

[Install]
WantedBy=multi-user.target
EOF

chmod 644 /etc/systemd/system/pmta2.service
systemctl daemon-reload
systemctl enable pmta2
systemctl restart pmta2

echo "===================================="
echo "PMTA2 Installed"
echo "SMTP: $pmtaip:$smtpport"
echo "WEB: http://$pmtaip:$webport"
echo "Config: $CONFDIR/config"
echo "Logs: $LOGDIR"
echo "===================================="
