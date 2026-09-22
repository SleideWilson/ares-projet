#!/usr/bin/env bash
set -euo pipefail

# Un paquet entre par eth1 avec une source dont la meilleure route retour passe
# par eth0. Un recepteur UDP permet de constater s'il atteint ou non la pile.

router_ns="m2d-rpf-router-$$"
left_ns="m2d-rpf-left-$$"
asym_ns="m2d-rpf-asym-$$"
tag=$((BASHPID % 100000))
left_if="m2a${tag}"
router_left_if="m2b${tag}"
asym_if="m2c${tag}"
router_asym_if="m2d${tag}"
receiver_pid=""
state_dir=""

cleanup() {
  local status=$?
  trap - EXIT INT TERM

  if [[ -n $receiver_pid ]]; then
    kill "$receiver_pid" 2>/dev/null || true
    wait "$receiver_pid" 2>/dev/null || true
  fi
  for namespace in "$router_ns" "$left_ns" "$asym_ns"; do
    ip netns delete "$namespace" >/dev/null 2>&1 || true
  done
  ip link delete "$left_if" >/dev/null 2>&1 || true
  ip link delete "$asym_if" >/dev/null 2>&1 || true
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

for command_name in ip sysctl python3 grep find mktemp; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Erreur : la commande '$command_name' est requise." >&2
    exit 1
  fi
done

set_rp_filter() {
  local mode=$1

  # La valeur effectivement appliquée est le maximum entre "all" et
  # l'interface. Mettre all à 0 permet de comparer précisément eth1.
  ip netns exec "$router_ns" sysctl -qw net.ipv4.conf.all.rp_filter=0
  ip netns exec "$router_ns" sysctl -qw net.ipv4.conf.default.rp_filter=0
  ip netns exec "$router_ns" sysctl -qw net.ipv4.conf.eth0.rp_filter=0
  ip netns exec "$router_ns" sysctl -qw "net.ipv4.conf.eth1.rp_filter=$mode"
}

send_and_observe() {
  local mode=$1
  local expected=$2
  local label=$3
  local result_file="$state_dir/result-$mode"

  set_rp_filter "$mode"
  ip netns exec "$router_ns" python3 -u -c '
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("10.120.0.1", 9999))
s.settimeout(1.2)
try:
    data, peer = s.recvfrom(512)
    print(f"RECU depuis {peer[0]}:{peer[1]} : {data.decode()}")
except TimeoutError:
    print("AUCUN PAQUET remis au processus")
s.close()
' >"$result_file" &
  receiver_pid=$!
  sleep 0.2

  ip netns exec "$asym_ns" python3 -c '
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("10.110.0.99", 0))
s.sendto(b"test rp_filter", ("10.120.0.1", 9999))
s.close()
'
  wait "$receiver_pid"
  receiver_pid=""

  echo
  echo "$label"
  ip netns exec "$router_ns" sysctl net.ipv4.conf.eth1.rp_filter
  cat "$result_file"

  if [[ $expected == received ]]; then
    grep -q '^RECU ' "$result_file" || {
      echo "Erreur : le paquet aurait dû être accepté." >&2
      exit 1
    }
  else
    grep -q '^AUCUN PAQUET' "$result_file" || {
      echo "Erreur : le paquet aurait dû être rejeté par rp_filter." >&2
      exit 1
    }
  fi
}

echo "=== Démo 11 : Reverse Path Filtering (rp_filter) ==="
echo "Le paquet entre par eth1 avec la source 10.110.0.99."
echo "Pourtant, la meilleure route de retour vers cette source passe par eth0."

ip netns add "$router_ns"
ip netns add "$left_ns"
ip netns add "$asym_ns"
ip link add "$left_if" type veth peer name "$router_left_if"
ip link add "$asym_if" type veth peer name "$router_asym_if"
ip link set "$left_if" netns "$left_ns" name eth0
ip link set "$router_left_if" netns "$router_ns" name eth0
ip link set "$asym_if" netns "$asym_ns" name eth0
ip link set "$router_asym_if" netns "$router_ns" name eth1

for namespace in "$router_ns" "$left_ns" "$asym_ns"; do
  ip -n "$namespace" link set lo up
done
ip -n "$left_ns" address add 10.110.0.2/24 dev eth0
ip -n "$router_ns" address add 10.110.0.1/24 dev eth0
ip -n "$router_ns" address add 10.120.0.1/24 dev eth1
ip -n "$asym_ns" address add 10.120.0.2/24 dev eth0
ip -n "$asym_ns" address add 10.110.0.99/32 dev eth0
ip -n "$left_ns" link set eth0 up
ip -n "$router_ns" link set eth0 up
ip -n "$router_ns" link set eth1 up
ip -n "$asym_ns" link set eth0 up
state_dir=$(mktemp -d /tmp/m2d-rpf.XXXXXX)

echo
echo "Décision de retour calculée par Linux :"
ip -n "$router_ns" route get 10.110.0.99
echo "Interface réelle d'entrée du paquet : eth1"

send_and_observe 0 received \
  "[1/3] Mode 0 — désactivé : aucun contrôle du chemin retour."
send_and_observe 1 dropped \
  "[2/3] Mode 1 — strict : retour par eth0 != entrée par eth1, donc rejet."
send_and_observe 2 received \
  "[3/3] Mode 2 — loose : une route vers la source existe, donc acceptation."

echo
echo "Conclusion : le mode strict protège contre certaines sources usurpées,"
echo "mais peut aussi supprimer un trafic légitime dans une architecture"
echo "asymétrique, multi-uplink, ECMP ou utilisant du policy routing."
