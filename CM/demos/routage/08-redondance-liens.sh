#!/usr/bin/env bash
set -euo pipefail

# Deux liens physiques sont regroupes dans un bond active-backup. La coupure
# du membre actif provoque une bascule automatique vers le lien de secours.

host_ns="m2d-bond-host-$$"
peer_ns="m2d-bond-peer-$$"
tag=$((BASHPID % 100000))
host_a="m2h${tag}a"
peer_a="m2p${tag}a"
host_b="m2h${tag}b"
peer_b="m2p${tag}b"

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  ip netns delete "$host_ns" >/dev/null 2>&1 || true
  ip netns delete "$peer_ns" >/dev/null 2>&1 || true
  ip link delete "$host_a" >/dev/null 2>&1 || true
  ip link delete "$host_b" >/dev/null 2>&1 || true
  exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if (( EUID != 0 )); then
  echo "Erreur : cette démonstration doit être exécutée en root." >&2
  exit 1
fi

for command_name in ip ping; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Erreur : la commande '$command_name' est requise." >&2
    exit 1
  fi
done

show_bond() {
  local namespace=$1
  local label=$2

  echo "$label"
  # shellcheck disable=SC2016 # $0 appartient au programme awk.
  ip netns exec "$namespace" awk '
    /Bonding Mode:|Currently Active Slave:|MII Status:|Slave Interface:/ {
      print "  " $0
    }
  ' /proc/net/bonding/bond0
}

echo "=== Démo 08 : redondance de liens avec un bond active-backup ==="
echo "Topologie : hôte == lien A + lien B == pair"
echo "Un seul membre transporte le trafic ; l'autre reste immédiatement disponible."

ip netns add "$host_ns"
ip netns add "$peer_ns"

ip link add "$host_a" type veth peer name "$peer_a"
ip link add "$host_b" type veth peer name "$peer_b"
ip link set "$host_a" netns "$host_ns" name link-a
ip link set "$host_b" netns "$host_ns" name link-b
ip link set "$peer_a" netns "$peer_ns" name link-a
ip link set "$peer_b" netns "$peer_ns" name link-b

for namespace in "$host_ns" "$peer_ns"; do
  ip -n "$namespace" link set lo up
  if ! ip -n "$namespace" link add bond0 type bond \
    mode active-backup miimon 100 primary link-a; then
    echo "Erreur : le noyau ne prend pas en charge le bonding Linux." >&2
    exit 1
  fi
  ip -n "$namespace" link set link-a master bond0
  ip -n "$namespace" link set link-b master bond0
  ip -n "$namespace" link set link-a up
  ip -n "$namespace" link set link-b up
  ip -n "$namespace" link set bond0 up
done

ip -n "$host_ns" address add 10.80.0.1/24 dev bond0
ip -n "$peer_ns" address add 10.80.0.2/24 dev bond0
sleep 0.3

echo
echo "[1/3] État initial : link-a est le membre actif et link-b le secours."
show_bond "$host_ns" "Bond côté hôte :"
show_bond "$peer_ns" "Bond côté pair :"
ip netns exec "$host_ns" ping -c 1 -W 1 10.80.0.2

echo
echo "[2/3] Simulation de panne : on coupe link-a côté hôte."
ip -n "$host_ns" link set link-a down
sleep 0.3
show_bond "$host_ns" "Après la panne, côté hôte :"
show_bond "$peer_ns" "Après la panne, côté pair :"

echo
echo "[3/3] Le service reste joignable par link-b."
ip netns exec "$host_ns" ping -c 3 -W 1 10.80.0.2

# shellcheck disable=SC2016 # $2 appartient au programme awk.
active_slave=$(ip netns exec "$host_ns" awk \
  -F ': ' '/Currently Active Slave:/ { print $2 }' /proc/net/bonding/bond0)
if [[ $active_slave != link-b ]]; then
  echo "Erreur : la bascule attendue vers link-b n'a pas eu lieu." >&2
  exit 1
fi

echo
echo "Conclusion : l'interface logique bond0 reste stable tandis que le pilote"
echo "retire le membre défaillant et active le lien de secours. Contrairement à"
echo "LACP/802.3ad, active-backup privilégie ici la simplicité de la redondance,"
echo "pas l'agrégation de capacité."
