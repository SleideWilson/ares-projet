#!/usr/bin/env bash
set -euo pipefail

# Une topologie unique illustre SNAT, MASQUERADE, DNAT, puis la difference
# entre filtrage stateless et stateful.

client_ns="m2d-nat-client-$$"
router_ns="m2d-nat-router-$$"
server_ns="m2d-nat-server-$$"
tag=$((BASHPID % 100000))
client_if="m2c${tag}"
router_lan_if="m2l${tag}"
router_wan_if="m2w${tag}"
server_if="m2s${tag}"
server_pid=""

cleanup() {
  local status=$?
  trap - EXIT INT TERM

  if [[ -n $server_pid ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  for namespace in "$client_ns" "$router_ns" "$server_ns"; do
    ip netns delete "$namespace" >/dev/null 2>&1 || true
  done
  ip link delete "$client_if" >/dev/null 2>&1 || true
  ip link delete "$router_wan_if" >/dev/null 2>&1 || true
  exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if (( EUID != 0 )); then
  echo "Erreur : cette démonstration doit être exécutée en root." >&2
  exit 1
fi

for command_name in ip nft conntrack python3; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Erreur : la commande '$command_name' est requise." >&2
    echo "Sous Debian/Ubuntu : sudo apt install iproute2 nftables conntrack python3" >&2
    exit 1
  fi
done

start_server() {
  ip netns exec "$server_ns" python3 -u -c '
import socket
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("198.51.100.10", 9000))
s.listen(1)
c, peer = s.accept()
local = c.getsockname()
message = (f"source vue={peer[0]}:{peer[1]} ; "
           f"destination vue={local[0]}:{local[1]}")
c.sendall(message.encode())
c.close()
s.close()
' &
  server_pid=$!
  sleep 0.2
}

stop_server() {
  if [[ -n $server_pid ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    server_pid=""
  fi
}

exchange() {
  local destination=$1
  local port=$2
  local expected_result=${3:-success}
  local output
  local status

  start_server
  set +e
  output=$(ip netns exec "$client_ns" python3 -c '
import socket, sys
s = socket.create_connection((sys.argv[1], int(sys.argv[2])), 1.5)
s.settimeout(1.5)
print(s.recv(512).decode())
s.close()
' "$destination" "$port" 2>&1)
  status=$?
  set -e
  stop_server

  if [[ $expected_result == success ]]; then
    if (( status != 0 )); then
      echo "Erreur : la connexion vers $destination:$port devait réussir." >&2
      echo "$output" >&2
      exit 1
    fi
    echo "$output"
  else
    if (( status == 0 )); then
      echo "Erreur : la connexion devait être bloquée, mais elle a réussi." >&2
      exit 1
    fi
    echo "Résultat attendu : connexion bloquée faute de règle retour."
  fi
}

show_nat_rules() {
  ip netns exec "$router_ns" nft list table ip m2_nat
}

echo "=== Démo 10 : NAT et filtrage stateless/stateful ==="
echo "Topologie : client -- routeur nftables -- serveur TCP"

ip netns add "$client_ns"
ip netns add "$router_ns"
ip netns add "$server_ns"
ip link add "$client_if" type veth peer name "$router_lan_if"
ip link add "$router_wan_if" type veth peer name "$server_if"
ip link set "$client_if" netns "$client_ns" name eth0
ip link set "$router_lan_if" netns "$router_ns" name lan0
ip link set "$router_wan_if" netns "$router_ns" name wan0
ip link set "$server_if" netns "$server_ns" name eth0

for namespace in "$client_ns" "$router_ns" "$server_ns"; do
  ip -n "$namespace" link set lo up
done
ip -n "$client_ns" address add 10.100.1.10/24 dev eth0
ip -n "$router_ns" address add 10.100.1.1/24 dev lan0
ip -n "$router_ns" address add 198.51.100.1/24 dev wan0
ip -n "$router_ns" address add 198.51.100.254/32 dev wan0
ip -n "$router_ns" address add 203.0.113.80/32 dev lo
ip -n "$server_ns" address add 198.51.100.10/24 dev eth0
ip -n "$client_ns" link set eth0 up
ip -n "$router_ns" link set lan0 up
ip -n "$router_ns" link set wan0 up
ip -n "$server_ns" link set eth0 up
ip -n "$client_ns" route add default via 10.100.1.1
ip -n "$server_ns" route add default via 198.51.100.1
ip netns exec "$router_ns" sysctl -qw net.ipv4.ip_forward=1

ip netns exec "$router_ns" nft -f - <<'EOF'
table ip m2_nat {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
  }
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
  }
}
EOF

echo
echo "[1/5] SNAT : une adresse source fixe est imposée à la sortie."
ip netns exec "$router_ns" nft add rule ip m2_nat postrouting \
  ip saddr 10.100.1.0/24 ip daddr 198.51.100.10 \
  counter snat to 198.51.100.254
exchange 198.51.100.10 9000
show_nat_rules

echo
echo "[2/5] MASQUERADE : la source devient l'adresse courante de wan0."
ip netns exec "$router_ns" nft flush chain ip m2_nat postrouting
ip netns exec "$router_ns" conntrack -F >/dev/null 2>&1 || true
ip netns exec "$router_ns" nft add rule ip m2_nat postrouting \
  ip saddr 10.100.1.0/24 oifname wan0 counter masquerade
exchange 198.51.100.10 9000
show_nat_rules

echo
echo "[3/5] DNAT : 203.0.113.80:8080 publie le service interne :9000."
ip netns exec "$router_ns" nft flush chain ip m2_nat postrouting
ip netns exec "$router_ns" conntrack -F >/dev/null 2>&1 || true
ip netns exec "$router_ns" nft add rule ip m2_nat prerouting \
  ip daddr 203.0.113.80 tcp dport 8080 counter \
  dnat to 198.51.100.10:9000
exchange 203.0.113.80 8080
show_nat_rules

ip netns exec "$router_ns" nft flush chain ip m2_nat prerouting
ip netns exec "$router_ns" conntrack -F >/dev/null 2>&1 || true
ip netns exec "$router_ns" nft -f - <<'EOF'
table inet m2_filter {
  chain forward {
    type filter hook forward priority filter; policy drop;
  }
}
EOF

echo
echo "[4/5] Filtrage stateless : seule la règle aller ne suffit pas."
ip netns exec "$router_ns" nft add rule inet m2_filter forward \
  ip saddr 10.100.1.0/24 ip daddr 198.51.100.10 \
  tcp dport 9000 counter accept
exchange 198.51.100.10 9000 failure
echo "On ajoute explicitement la règle symétrique pour les réponses."
ip netns exec "$router_ns" nft add rule inet m2_filter forward \
  ip saddr 198.51.100.10 ip daddr 10.100.1.0/24 \
  tcp sport 9000 counter accept
exchange 198.51.100.10 9000
ip netns exec "$router_ns" nft list chain inet m2_filter forward

echo
echo "[5/5] Filtrage stateful : conntrack reconnaît automatiquement le retour."
ip netns exec "$router_ns" nft flush chain inet m2_filter forward
ip netns exec "$router_ns" conntrack -F >/dev/null 2>&1 || true
ip netns exec "$router_ns" nft add rule inet m2_filter forward \
  ct state established,related counter accept
ip netns exec "$router_ns" nft add rule inet m2_filter forward \
  ip saddr 10.100.1.0/24 ip daddr 198.51.100.10 \
  tcp dport 9000 ct state new counter accept
exchange 198.51.100.10 9000
ip netns exec "$router_ns" nft list chain inet m2_filter forward
echo "État conntrack observé :"
ip netns exec "$router_ns" conntrack -L -p tcp 2>/dev/null || \
  echo "L'entrée a déjà expiré ; les compteurs nftables restent disponibles."

echo
echo "Conclusion : SNAT impose une source, MASQUERADE utilise l'adresse de"
echo "sortie, DNAT publie une destination, le stateless exige les deux sens et"
echo "le stateful autorise le retour en s'appuyant sur l'état conntrack."
