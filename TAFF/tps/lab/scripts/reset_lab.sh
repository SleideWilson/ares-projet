#!/usr/bin/env bash
set -euo pipefail

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root: sudo $0" >&2
    exit 1
  fi
}

delete_ns() {
  local ns="$1"
  if ip netns list | awk '{print $1}' | grep -qx "$ns"; then
    ip netns delete "$ns"
  fi
}

require_root

state_dir=/run/ares-lab

if [ -f "$state_dir/ip_forward.before" ]; then
  ip rule delete priority 100 from 10.10.10.0/24 table users 2>/dev/null || true
  ip rule delete priority 200 from 10.10.250.0/24 table admin 2>/dev/null || true
  ip route flush table users 2>/dev/null || true
  ip route flush table admin 2>/dev/null || true
fi

for ns in ns_user ns_prod ns_admin ns_inet ns_site_a ns_site_b ns_host_a ns_host_b ns_vtep_a ns_vtep_b; do
  delete_ns "$ns"
done

for link in r-user r-prod r-admin r-inet underlay-a underlay-b; do
  if ip link show "$link" >/dev/null 2>&1; then
    ip link delete "$link"
  fi
done

if nft list table inet ares_filter >/dev/null 2>&1; then
  nft delete table inet ares_filter
fi
if nft list table ip ares_nat >/dev/null 2>&1; then
  nft delete table ip ares_nat
fi

if [ -f "$state_dir/ip_forward.before" ]; then
  sysctl -w "net.ipv4.ip_forward=$(cat "$state_dir/ip_forward.before")" >/dev/null
  if [ ! -f "$state_dir/users_table.preexisting" ]; then
    sed -i '/^100 users$/d' /etc/iproute2/rt_tables
  fi
  if [ ! -f "$state_dir/admin_table.preexisting" ]; then
    sed -i '/^200 admin$/d' /etc/iproute2/rt_tables
  fi
fi
rm -f "$state_dir/ip_forward.before" "$state_dir/users_table.preexisting" "$state_dir/admin_table.preexisting"
rmdir "$state_dir" 2>/dev/null || true

echo "ARES lab reset complete."
