#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

./scripts/reset_lab.sh

# Certaines installations d'iproute2 ne fournissent pas encore ce fichier local.
mkdir -p /etc/iproute2
if [ ! -e /etc/iproute2/rt_tables ]; then
  touch /etc/iproute2/rt_tables
fi

state_dir=/run/ares-lab
mkdir -p "$state_dir"
sysctl -n net.ipv4.ip_forward > "$state_dir/ip_forward.before"
if grep -q '^100 users$' /etc/iproute2/rt_tables; then
  : > "$state_dir/users_table.preexisting"
fi
if grep -q '^200 admin$' /etc/iproute2/rt_tables; then
  : > "$state_dir/admin_table.preexisting"
fi

ip netns add ns_user
ip netns add ns_prod
ip netns add ns_admin
ip netns add ns_inet

ip link add u0 type veth peer name r-user
ip link set u0 netns ns_user
ip addr add 10.10.10.1/24 dev r-user
ip link set r-user up
ip -n ns_user addr add 10.10.10.10/24 dev u0
ip -n ns_user link set lo up
ip -n ns_user link set u0 up
ip -n ns_user route add default via 10.10.10.1

ip link add p0 type veth peer name r-prod
ip link set p0 netns ns_prod
ip addr add 10.20.0.1/24 dev r-prod
ip link set r-prod up
ip -n ns_prod addr add 10.20.0.10/24 dev p0
ip -n ns_prod link set lo up
ip -n ns_prod link set p0 up
ip -n ns_prod route add default via 10.20.0.1

ip link add a0 type veth peer name r-admin
ip link set a0 netns ns_admin
ip addr add 10.10.250.1/24 dev r-admin
ip link set r-admin up
ip -n ns_admin addr add 10.10.250.10/24 dev a0
ip -n ns_admin link set lo up
ip -n ns_admin link set a0 up
ip -n ns_admin route add default via 10.10.250.1

ip link add i0 type veth peer name r-inet
ip link set i0 netns ns_inet
ip addr add 203.0.113.1/30 dev r-inet
ip link set r-inet up
ip -n ns_inet addr add 203.0.113.2/30 dev i0
ip -n ns_inet link set lo up
ip -n ns_inet link set i0 up
ip -n ns_inet route add default via 203.0.113.1

sysctl -w net.ipv4.ip_forward=1 >/dev/null

grep -q "^100 users$" /etc/iproute2/rt_tables || echo "100 users" >> /etc/iproute2/rt_tables
grep -q "^200 admin$" /etc/iproute2/rt_tables || echo "200 admin" >> /etc/iproute2/rt_tables

ip route replace default via 203.0.113.2 dev r-inet table users
ip route replace 10.20.0.0/24 dev r-prod table users
ip route replace default via 203.0.113.2 dev r-inet table admin
ip route replace 10.20.0.0/24 dev r-prod table admin
ip rule add from 10.10.10.0/24 table users priority 100 2>/dev/null || true
ip rule add from 10.10.250.0/24 table admin priority 200 2>/dev/null || true

echo "Dataplane lab ready."
echo "Try: sudo ./scripts/test_dataplane_lab.sh"
