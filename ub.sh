#!/bin/bash
set -e

### --- PRECHECKS ---
if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root."
    exit 1
fi

echo ""
echo "=== Second PMTA Instance Installer (PMTA2) ==="
echo ""

read -p "PMTA2 IP: " pmtaip
read -p "PMTA2 hostname: " pmtahostname
read -p "PMTA2 SMTP port: " pmtaport
read -p "PMTA2 HTTP admin port: " pmtahttpport

if [[ ! $pmtaip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Invalid IP."
    exit 1
fi

### --- DIRECTORIES ---
mkdir -p /etc/pmta2
mkdir -p /var/log/pmta2

### --- CREATE USER ---
if ! id "pmta2" >/dev/null 2>&1; then
    groupadd --system pmta2 || true
    useradd --system --no-create-home --home-dir /etc/pmta2 --shell /bin/false -g pmta2 pmta2
fi

### --- DOWNLOAD FILES ---
files=(
    "powermta.deb https://raw.githubusercontent.com/19965/sh/main/powermta_4.0r6-201204021810_amd64.deb"
    "pmta https://raw.githubusercontent.com/19965/sh/main/pmta"
    "pmtad https://raw.githubusercontent.com/19965/sh/main/pmtad"
    "pmtahttpd https://raw.githubusercontent.com/19965/sh/main/pmtahttpd"
    "pmtasnmpd https://raw.githubusercontent.com/19965/sh/main/pmtasnmpd"
    "license https://raw.githubusercontent.com/19965/sh/main/license"
    "config https://raw.githubusercontent.com/19965/sh/main/config"
)

for entry in "${files[@]}"; do
    name=$(echo $entry | awk '{print $1}')
    url=$(echo $entry | awk '{print $2}')
    wget -q -O "$name" "$url"
done

### --- INSTALL PMTA PACKAGE ---
dpkg -x powermta.deb /tmp/pmta2_extract

cp /tmp/pmta2_extract/usr/sbin/* /usr/sbin/pmta2- 2>/dev/null || true
cp -r /tmp/pmta2_extract/etc/pmta/* /etc/pmta2/

### --- COPY CUSTOM FILES ---
cp -f config /etc/pmta2/
cp -f license /etc/pmta2/
cp -f pmta /usr/sbin/pmta2
cp -f pmtad /usr/sbin/pmtad2
cp -f pmtahttpd /usr/sbin/pmtahttpd2
cp -f pmtasnmpd /usr/sbin/pmtasnmpd2

### --- CONFIG UPDATE ---
sed -i "s/QQQipQQQ/$pmtaip/g"   /etc/pmta2/config
sed -i "s/QQQhostnameQQQ/$pmtahostname/g" /etc/pmta2/config
sed -i "s/QQQportQQQ/$pmtaport/g" /etc/pmta2/config
sed -i "s/8890/$pmtahttpport/g" /etc/pmta2/config

### --- PERMISSIONS ---
chown -R pmta2:pmta2 /etc/pmta2
chown -R pmta2:pmta2 /var/log/pmta2
chmod 600 /etc/pmta2/license

### --- CREATE SYSTEMD SERVICE ---
cat > /etc/systemd/system/pmta2.service <<EOF
[Unit]
Description=PowerMTA 2
After=network.target

[Service]
Type=forking
User=pmta2
Group=pmta2
ExecStart=/usr/sbin/pmta2 -c /etc/pmta2/config
PIDFile=/etc/pmta2/pmta.pid
Restart=always

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/pmtahttp2.service <<EOF
[Unit]
Description=PowerMTA2 HTTP admin
After=pmta2.service

[Service]
Type=simple
User=pmta2
Group=pmta2
ExecStart=/usr/sbin/pmtahttpd2 -c /etc/pmta2/config
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

### --- START SERVICES ---
systemctl daemon-reload
systemctl enable pmta2
systemctl enable pmtahttp2
systemctl restart pmta2
systemctl restart pmtahttp2

echo ""
echo "=============================="
echo " PMTA2 installed successfully!"
echo " Hostname: $pmtahostname"
echo " SMTP Port: $pmtaport"
echo " HTTP Admin Port: $pmtahttpport"
echo "=============================="
