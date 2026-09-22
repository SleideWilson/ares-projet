#!/usr/bin/env bash
set -euo pipefail

# Deux routeurs Keepalived portent une passerelle virtuelle VRRP. Le client et
# le serveur conservent la meme route pendant que la VIP change de routeur.

client_ns="m2d-gw-client-$$"
r1_ns="m2d-gw-r1-$$"
r2_ns="m2d-gw-r2-$$"
server_ns="m2d-gw-server-$$"
fabric_ns="m2d-gw-fabric-$$"
tag=$((BASHPID % 100000))
port_index=0
r1_pid=""
r2_pid=""
state_dir=""

cleanup() {
  local status=$?
  trap - EXIT INT TERM

  if [[ -n $r1_pid ]]; then
    kill "$r1_pid" 2>/dev/null || true
    wait "$r1_pid" 2>/dev/null || true
  fi
  if [[ -n $r2_pid ]]; then
    kill "$r2_pid" 2>/dev/null || true
    wait "$r2_pid" 2>/dev/null || true
  fi

  for namespace in \
    "$client_ns" "$r1_ns" "$r2_ns" "$server_ns" "$fabric_ns"; do
    ip netns delete "$namespace" >/dev/null 2>&1 || true
  done

  if [[ -n $state_dir && -d $state_dir ]]; then
    find "$state_dir" -type f -delete 2>/dev/null || true
    rmdir "$state_dir" 2>/dev/null || true
  fi

  exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if (( EUID != 0 )); then
  echo "Erreur : cette démonstration doit être exécutée en root." >&2
  exit 1
fi

for command_name in ip ping keepalived awk find mktemp; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Erreur : la commande '$command_name' est requise." >&2
    echo "Sous Debian/Ubuntu : sudo apt install keepalived iproute2 iputils-ping" >&2
    exit 1
  fi
done

connect_to_bridge() {
  local namespace=$1
  local interface=$2
  local bridge=$3
  local endpoint
  local switch_port

  port_index=$((port_index + 1))
  endpoint="m2e${tag}${port_index}"
  switch_port="p${port_index}"

  ip link add "$endpoint" type veth peer name "${endpoint}p"
  ip link set "$endpoint" netns "$namespace" name "$interface"
  ip link set "${endpoint}p" netns "$fabric_ns" name "$switch_port"
  ip -n "$namespace" link set "$interface" up
  ip -n "$fabric_ns" link set "$switch_port" master "$bridge"
  ip -n "$fabric_ns" link set "$switch_port" up
}

wait_for_vip() {
  local namespace=$1
  local interface=$2
  local vip=$3
  local attempt

  for ((attempt = 0; attempt < 50; attempt++)); do
    if ip -n "$namespace" address show dev "$interface" | grep -q " $vip/"; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

show_vrrp_owner() {
  local owner="aucun"

  if ip -n "$r1_ns" address show dev lan0 | grep -q ' 10.90.0.254/'; then
    owner="routeur 1"
  elif ip -n "$r2_ns" address show dev lan0 | grep -q ' 10.90.0.254/'; then
    owner="routeur 2"
  fi
  echo "Propriétaire actuel de la VIP 10.90.0.254 : $owner"
}

echo "=== Démo 09 : redondance des passerelles avec VRRP ==="
echo "Topologie : client -- [routeur 1 | routeur 2] -- serveur"
echo "Les hôtes utilisent des VIP ; ils ne connaissent pas le routeur actif."

for namespace in \
  "$client_ns" "$r1_ns" "$r2_ns" "$server_ns" "$fabric_ns"; do
  ip netns add "$namespace"
  ip -n "$namespace" link set lo up
done

ip -n "$fabric_ns" link add br-lan type bridge
ip -n "$fabric_ns" link add br-wan type bridge
ip -n "$fabric_ns" link set br-lan up
ip -n "$fabric_ns" link set br-wan up

connect_to_bridge "$client_ns" eth0 br-lan
connect_to_bridge "$r1_ns" lan0 br-lan
connect_to_bridge "$r2_ns" lan0 br-lan
connect_to_bridge "$r1_ns" wan0 br-wan
connect_to_bridge "$r2_ns" wan0 br-wan
connect_to_bridge "$server_ns" eth0 br-wan

ip -n "$client_ns" address add 10.90.0.10/24 dev eth0
ip -n "$r1_ns" address add 10.90.0.1/24 dev lan0
ip -n "$r2_ns" address add 10.90.0.2/24 dev lan0
ip -n "$r1_ns" address add 10.91.0.1/24 dev wan0
ip -n "$r2_ns" address add 10.91.0.2/24 dev wan0
ip -n "$server_ns" address add 10.91.0.10/24 dev eth0
ip -n "$client_ns" route add default via 10.90.0.254
ip -n "$server_ns" route add default via 10.91.0.254
ip netns exec "$r1_ns" sysctl -qw net.ipv4.ip_forward=1
ip netns exec "$r2_ns" sysctl -qw net.ipv4.ip_forward=1

state_dir=$(mktemp -d /tmp/m2d-vrrp.XXXXXX)

cat >"$state_dir/r1.conf" <<EOF
global_defs {
  router_id M2_DEMO_R1
}
vrrp_instance M2_GATEWAY {
  state MASTER
  interface lan0
  virtual_router_id 90
  priority 150
  advert_int 1
  authentication {
    auth_type PASS
    auth_pass m2demo90
  }
  virtual_ipaddress {
    10.90.0.254/24 dev lan0
    10.91.0.254/24 dev wan0
  }
}
EOF

cat >"$state_dir/r2.conf" <<EOF
global_defs {
  router_id M2_DEMO_R2
}
vrrp_instance M2_GATEWAY {
  state BACKUP
  interface lan0
  virtual_router_id 90
  priority 100
  advert_int 1
  authentication {
    auth_type PASS
    auth_pass m2demo90
  }
  virtual_ipaddress {
    10.90.0.254/24 dev lan0
    10.91.0.254/24 dev wan0
  }
}
EOF

ip netns exec "$r1_ns" keepalived --dont-fork --log-console \
  --use-file "$state_dir/r1.conf" --pid "$state_dir/r1.pid" \
  --vrrp_pid "$state_dir/r1-vrrp.pid" >"$state_dir/r1.log" 2>&1 &
r1_pid=$!
ip netns exec "$r2_ns" keepalived --dont-fork --log-console \
  --use-file "$state_dir/r2.conf" --pid "$state_dir/r2.pid" \
  --vrrp_pid "$state_dir/r2-vrrp.pid" >"$state_dir/r2.log" 2>&1 &
r2_pid=$!

if ! wait_for_vip "$r1_ns" lan0 10.90.0.254; then
  echo "Erreur : le routeur 1 n'est pas devenu maître VRRP." >&2
  sed -n '1,80p' "$state_dir/r1.log" >&2
  exit 1
fi

echo
echo "[1/3] Le routeur 1, de priorité supérieure, porte les deux VIP."
show_vrrp_owner
ip -n "$r1_ns" -br address show lan0
ip -n "$r1_ns" -br address show wan0
ip netns exec "$client_ns" ping -c 2 -W 1 10.91.0.10
echo "Voisin ARP utilisé par le client :"
ip -n "$client_ns" neighbor show 10.90.0.254

echo
echo "[2/3] Panne simulée : arrêt de Keepalived sur le routeur 1."
kill "$r1_pid"
wait "$r1_pid" 2>/dev/null || true
r1_pid=""

if ! wait_for_vip "$r2_ns" lan0 10.90.0.254; then
  echo "Erreur : le routeur 2 n'a pas repris la passerelle virtuelle." >&2
  sed -n '1,120p' "$state_dir/r2.log" >&2
  exit 1
fi
show_vrrp_owner
ip -n "$r2_ns" -br address show lan0

echo
echo "[3/3] La route par défaut ne change pas et le transit fonctionne encore."
ip -n "$client_ns" route show default
ip netns exec "$client_ns" ping -c 3 -W 1 10.91.0.10
echo "Entrée ARP après l'annonce gratuite du nouveau maître :"
ip -n "$client_ns" neighbor show 10.90.0.254

echo
echo "Conclusion : VRRP dissocie l'adresse de passerelle d'un routeur physique."
echo "La VIP bascule, Keepalived émet une annonce ARP et les hôtes conservent"
echo "leur configuration. La continuité de la VIP ne garantit toutefois pas à"
echo "elle seule la continuité des sessions stateful ou des services hébergés."
