#!/usr/bin/env bash

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y dnsmasq curl ca-certificates tcpdump
pxe_iface=$(ip -o -4 addr show | awk '$4 == "192.168.77.10/24" {print $2}')
test -n "$pxe_iface"
mkdir -p /srv/tftp
curl --fail --location --retry 3 \
  https://deb.debian.org/debian/dists/bookworm/main/installer-amd64/current/images/netboot/netboot.tar.gz \
  -o /tmp/pxe-netboot.tar.gz
tar -xzf /tmp/pxe-netboot.tar.gz -C /srv/tftp
test -f /srv/tftp/pxelinux.0
chmod -R a+rX /srv/tftp
cat > /etc/dnsmasq.d/pxe-lab.conf <<EOF
port=0
interface=$pxe_iface
bind-interfaces
dhcp-authoritative
dhcp-range=192.168.77.100,192.168.77.150,255.255.255.0,1h
dhcp-option=option:router
dhcp-option=option:dns-server
dhcp-boot=pxelinux.0,pxe-server,192.168.77.10
enable-tftp
tftp-root=/srv/tftp
log-dhcp
EOF
dnsmasq --test
systemctl enable dnsmasq
systemctl restart dnsmasq
systemctl is-active dnsmasq
