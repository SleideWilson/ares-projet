#!/usr/bin/env bash
set -euo pipefail

client_ns=m2d-fw-client
server_ns=m2d-fw-server
client_if=m2dfwc
server_if=m2dfws

cleanup() {
  ip netns delete "$client_ns" 2>/dev/null || true
  ip netns delete "$server_ns" 2>/dev/null || true
}

pause() {
  if [[ ${DEMO_PAUSE:-1} != 0 && -t 0 ]]; then
    read -r -p "Appuyez sur Entrée pour continuer... " _
  fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Commande requise absente : $1" >&2
    exit 1
  }
}

if [[ ${EUID} -ne 0 ]]; then
  echo "Exécutez avec les privilèges root : sudo $0" >&2
  exit 1
fi

for command_name in ip ping nft conntrack; do
  require_command "$command_name"
done

trap cleanup EXIT INT TERM
cleanup

echo "=== Démo 07 : une route correcte ne garantit pas le passage ==="
echo "Topologie : client 10.70.0.1 --- serveur 10.70.0.2"

ip netns add "$client_ns"
ip netns add "$server_ns"
ip link add "$client_if" type veth peer name "$server_if"
ip link set "$client_if" netns "$client_ns"
ip link set "$server_if" netns "$server_ns"
ip -n "$client_ns" link set lo up
ip -n "$server_ns" link set lo up
ip -n "$client_ns" address add 10.70.0.1/24 dev "$client_if"
ip -n "$server_ns" address add 10.70.0.2/24 dev "$server_if"
ip -n "$client_ns" link set "$client_if" up
ip -n "$server_ns" link set "$server_if" up

ip netns exec "$server_ns" nft -f - <<'EOF'
table inet m2demo {
  chain input {
    type filter hook input priority filter; policy drop;
  }
  chain output {
    type filter hook output priority filter; policy drop;
  }
}
EOF

echo
echo "[1/3] La route et le voisin sont valides, mais la policy DROP bloque le ping."
ip -n "$client_ns" route get 10.70.0.2
if ip netns exec "$client_ns" ping -c 1 -W 1 10.70.0.2 >/dev/null 2>&1; then
  echo "ERREUR : le ping aurait dû être bloqué." >&2
  exit 1
else
  echo "Résultat attendu : aucune réponse."
fi
pause

echo
echo "[2/3] On autorise les flux établis, puis les nouvelles requêtes ICMP."
ip netns exec "$server_ns" nft add rule inet m2demo input \
  ct state established,related counter accept
ip netns exec "$server_ns" nft add rule inet m2demo input \
  icmp type echo-request ct state new counter accept
ip netns exec "$server_ns" nft add rule inet m2demo output \
  ct state established,related counter accept
ip netns exec "$server_ns" nft list ruleset
pause

echo
echo "[3/3] Le même ping passe ; compteurs et conntrack prouvent l'état du flux."
ip netns exec "$client_ns" ping -c 2 -W 1 10.70.0.2
echo
ip netns exec "$server_ns" nft list chain inet m2demo input
ip netns exec "$server_ns" nft list chain inet m2demo output
echo
ip netns exec "$server_ns" conntrack -L -p icmp 2>/dev/null || \
  echo "L'entrée ICMP a déjà expiré ; les compteurs nftables restent la preuve."

echo
echo "Conclusion : la FIB choisit le chemin, nftables autorise le passage,"
echo "et conntrack reconnaît les paquets appartenant au même échange."
