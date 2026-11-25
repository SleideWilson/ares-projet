#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

echo "== gateway tunnel pings (local INPUT/OUTPUT, not LAN transit) =="
ip netns exec ns_site_a ping -W 2 -c 2 10.200.0.2
ip netns exec ns_site_b ping -W 2 -c 2 10.200.0.1

echo "== source-based routing decision (independent of filtering) =="
ip -n ns_site_a rule show
host_route="$(ip -n ns_site_a route get 10.100.2.10 from 10.100.1.10 iif lan-a)"
gateway_route="$(ip -n ns_site_a route get 10.100.2.10)"
printf '%s\n' "$host_route" "$gateway_route"
if [[ "$host_route" != *"table 100"* || "$host_route" != *"dev wg0"* ]]; then
  echo "FAIL: host A traffic must select table 100 and wg0." >&2
  exit 1
fi
if [[ "$gateway_route" == *"table 100"* || "$gateway_route" != *"dev wg0"* ]]; then
  echo "FAIL: gateway traffic must select the main route through wg0." >&2
  exit 1
fi

echo "== LAN transit A -> B (FORWARD on both gateways) =="
ip netns exec ns_host_a ping -W 2 -c 2 10.100.2.10

echo "== new LAN requests B -> A must be dropped by site B =="
drop_count() {
  ip netns exec ns_site_b nft list counter inet ares_wg denied_b_to_a |
    awk '/packets/ { for (i=1; i<=NF; i++) if ($i == "packets") print $(i+1) }'
}
before="$(drop_count)"
if ip netns exec ns_host_b ping -W 1 -c 2 10.100.1.10; then
  echo "FAIL: B -> A unexpectedly allowed." >&2
  exit 1
fi
after="$(drop_count)"
if [[ ! "$before" =~ ^[0-9]+$ || ! "$after" =~ ^[0-9]+$ ]] || (( after <= before )); then
  echo "FAIL: ping failed without an increased firewall drop counter." >&2
  exit 1
fi
printf 'PASS: denied_b_to_a packets %s -> %s\n' "$before" "$after"

echo "== MTU probe from LAN A =="
ip netns exec ns_host_a ping -W 2 -M "do" -s 1200 -c 1 10.100.2.10

echo "== tunnel and forwarding evidence =="
for site in a b; do
  ip netns exec "ns_site_$site" wg show
  ip netns exec "ns_site_$site" nft list table inet ares_wg
done

echo "PASS: tunnel, source routing, LAN transit, filtering and MTU probe."
