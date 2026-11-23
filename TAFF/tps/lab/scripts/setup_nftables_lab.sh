#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

if ! ip netns list | awk '{print $1}' | grep -qx ns_user; then
  ./scripts/setup_dataplane_lab.sh
fi

if nft list table inet ares_filter >/dev/null 2>&1; then
  nft delete table inet ares_filter
fi
if nft list table ip ares_nat >/dev/null 2>&1; then
  nft delete table ip ares_nat
fi

nft add table inet ares_filter
nft add chain inet ares_filter forward '{ type filter hook forward priority 0; policy accept; }'
nft add rule inet ares_filter forward ct state established,related accept
nft add rule inet ares_filter forward ip saddr 10.10.10.0/24 ip daddr 10.20.0.10 tcp dport 443 accept
nft add rule inet ares_filter forward ip saddr 10.10.250.0/24 ip daddr 10.20.0.0/24 accept
nft add rule inet ares_filter forward ip saddr 10.10.10.0/24 ip daddr 203.0.113.2 icmp type echo-request accept
nft add rule inet ares_filter forward iifname '{ r-user, r-admin, r-prod, r-inet }' counter log prefix '"ARES_DROP "' drop
nft add rule inet ares_filter forward oifname '{ r-user, r-admin, r-prod, r-inet }' counter log prefix '"ARES_DROP "' drop

nft add table ip ares_nat
nft add chain ip ares_nat postrouting '{ type nat hook postrouting priority 100; policy accept; }'
nft add rule ip ares_nat postrouting ip saddr 10.10.10.0/24 oif r-inet masquerade

echo "nftables lab ready."
echo "Allowed: admin -> prod, user -> prod tcp/443, user -> inet ping."
