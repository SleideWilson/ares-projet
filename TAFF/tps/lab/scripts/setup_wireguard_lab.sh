#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

for tool in ip wg nft sysctl; do
  command -v "$tool" >/dev/null || {
    echo "$tool is required for this lab." >&2
    exit 1
  }
done

./scripts/reset_lab.sh

ip netns add ns_site_a
ip netns add ns_site_b
ip netns add ns_host_a
ip netns add ns_host_b

ip link add underlay-a type veth peer name underlay-b
ip link set underlay-a netns ns_site_a
ip link set underlay-b netns ns_site_b
ip -n ns_site_a addr add 192.0.2.1/30 dev underlay-a
ip -n ns_site_b addr add 192.0.2.2/30 dev underlay-b
ip -n ns_site_a link set lo up
ip -n ns_site_b link set lo up
ip -n ns_site_a link set underlay-a up
ip -n ns_site_b link set underlay-b up

key_a="$(wg genkey)"
pub_a="$(printf '%s' "$key_a" | wg pubkey)"
key_b="$(wg genkey)"
pub_b="$(printf '%s' "$key_b" | wg pubkey)"

ip -n ns_site_a link add wg0 type wireguard
ip -n ns_site_b link add wg0 type wireguard
ip netns exec ns_site_a wg set wg0 private-key <(printf '%s\n' "$key_a") listen-port 51820 peer "$pub_b" allowed-ips 10.200.0.2/32,10.100.2.0/24 endpoint 192.0.2.2:51820
ip netns exec ns_site_b wg set wg0 private-key <(printf '%s\n' "$key_b") listen-port 51820 peer "$pub_a" allowed-ips 10.200.0.1/32,10.100.1.0/24 endpoint 192.0.2.1:51820

ip -n ns_site_a addr add 10.200.0.1/30 dev wg0
ip -n ns_site_b addr add 10.200.0.2/30 dev wg0
ip -n ns_site_a link set wg0 up
ip -n ns_site_b link set wg0 up
ip -n ns_site_a route add 10.100.2.0/24 dev wg0
ip -n ns_site_b route add 10.100.1.0/24 dev wg0

# Real LAN hosts keep forwarded traffic separate from gateway-local traffic.
for site in a b; do
  if [ "$site" = a ]; then subnet=1; else subnet=2; fi
  ip link add "lan-$site" type veth peer name "host-$site"
  ip link set "lan-$site" netns "ns_site_$site"
  ip link set "host-$site" netns "ns_host_$site"
  ip -n "ns_host_$site" link set "host-$site" name eth0
  ip -n "ns_site_$site" addr add "10.100.$subnet.1/24" dev "lan-$site"
  ip -n "ns_host_$site" addr add "10.100.$subnet.10/24" dev eth0
  ip -n "ns_site_$site" link set "lan-$site" up
  ip -n "ns_host_$site" link set eth0 up
  ip -n "ns_host_$site" link set lo up
  ip -n "ns_host_$site" route add default via "10.100.$subnet.1"
  ip netns exec "ns_site_$site" sysctl -qw net.ipv4.ip_forward=1
  ip netns exec "ns_site_$site" nft -f - <<'NFT'
table inet ares_wg {
  counter denied_b_to_a {}
  chain forward {
    type filter hook forward priority 0; policy drop;
    ct state established,related counter accept
    ip saddr 10.100.1.10 ip daddr 10.100.2.10 icmp type echo-request counter accept
    ip saddr 10.100.2.10 ip daddr 10.100.1.10 icmp type echo-request counter name denied_b_to_a drop
  }
}
NFT
done

# The same encrypted path is selected through a source-specific routing table.
# Filtering remains a separate decision; this rule grants no access.
ip -n ns_site_a route add table 100 10.100.2.0/24 dev wg0
ip -n ns_site_a rule add priority 100 from 10.100.1.10/32 lookup 100

echo "WireGuard LAN transit lab ready (A -> B allowed, new B -> A pings denied)."
