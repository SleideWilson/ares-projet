#!/usr/bin/env bash
set -euo pipefail

readonly NS_CLIENT="m2-fwd-c-${BASHPID}"
readonly NS_ROUTER="m2-fwd-r-${BASHPID}"
readonly NS_SERVER="m2-fwd-s-${BASHPID}"
readonly IF_CLIENT="m2c${BASHPID}"
readonly IF_ROUTER_C="m2r1${BASHPID}"
readonly IF_ROUTER_S="m2r2${BASHPID}"
readonly IF_SERVER="m2s${BASHPID}"
readonly CLIENT_IP="10.203.1.2"
readonly ROUTER_C_IP="10.203.1.1"
readonly ROUTER_S_IP="10.203.2.1"
readonly SERVER_IP="10.203.2.2"

client_created=0
router_created=0
server_created=0

cleanup() {
    local status=$?
    trap - EXIT INT TERM

    if (( client_created )); then
        ip netns del "$NS_CLIENT" >/dev/null 2>&1 || true
    fi
    if (( router_created )); then
        ip netns del "$NS_ROUTER" >/dev/null 2>&1 || true
    fi
    if (( server_created )); then
        ip netns del "$NS_SERVER" >/dev/null 2>&1 || true
    fi

    # Nettoie aussi une paire veth restee dans le namespace initial apres
    # une erreur de configuration partielle.
    ip link del "$IF_CLIENT" >/dev/null 2>&1 || true
    ip link del "$IF_ROUTER_C" >/dev/null 2>&1 || true
    ip link del "$IF_ROUTER_S" >/dev/null 2>&1 || true
    ip link del "$IF_SERVER" >/dev/null 2>&1 || true

    exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if (( EUID != 0 )); then
    echo "Erreur : cette demonstration doit etre executee en root (utilisez sudo)." >&2
    exit 1
fi

for tool in ip ping sysctl; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Erreur : l'outil requis '$tool' est introuvable." >&2
        exit 1
    fi
done

echo "=== Routage IPv4, forwarding et TTL ==="
echo "Topologie : client -- routeur -- serveur"

ip netns add "$NS_CLIENT"
client_created=1
ip netns add "$NS_ROUTER"
router_created=1
ip netns add "$NS_SERVER"
server_created=1

ip link add "$IF_CLIENT" type veth peer name "$IF_ROUTER_C"
ip link add "$IF_ROUTER_S" type veth peer name "$IF_SERVER"
ip link set "$IF_CLIENT" netns "$NS_CLIENT"
ip link set "$IF_ROUTER_C" netns "$NS_ROUTER"
ip link set "$IF_ROUTER_S" netns "$NS_ROUTER"
ip link set "$IF_SERVER" netns "$NS_SERVER"

for ns in "$NS_CLIENT" "$NS_ROUTER" "$NS_SERVER"; do
    ip -n "$ns" link set lo up
done

ip -n "$NS_CLIENT" address add "$CLIENT_IP/24" dev "$IF_CLIENT"
ip -n "$NS_ROUTER" address add "$ROUTER_C_IP/24" dev "$IF_ROUTER_C"
ip -n "$NS_ROUTER" address add "$ROUTER_S_IP/24" dev "$IF_ROUTER_S"
ip -n "$NS_SERVER" address add "$SERVER_IP/24" dev "$IF_SERVER"

ip -n "$NS_CLIENT" link set "$IF_CLIENT" up
ip -n "$NS_ROUTER" link set "$IF_ROUTER_C" up
ip -n "$NS_ROUTER" link set "$IF_ROUTER_S" up
ip -n "$NS_SERVER" link set "$IF_SERVER" up

ip -n "$NS_CLIENT" route add 10.203.2.0/24 via "$ROUTER_C_IP"
ip -n "$NS_SERVER" route add 10.203.1.0/24 via "$ROUTER_S_IP"

echo
echo "Activation du forwarding uniquement dans le namespace du routeur :"
ip netns exec "$NS_ROUTER" sysctl -qw net.ipv4.ip_forward=1
ip netns exec "$NS_ROUTER" sysctl net.ipv4.ip_forward

echo
echo "Chemin choisi par chaque machine :"
echo "Client vers serveur :"
ip -n "$NS_CLIENT" -4 route get "$SERVER_IP"
echo "Routeur vers serveur :"
ip -n "$NS_ROUTER" -4 route get "$SERVER_IP"
echo "Serveur vers client (chemin retour) :"
ip -n "$NS_SERVER" -4 route get "$CLIENT_IP"

echo
echo "Test avec TTL=1 : le premier routeur decremente le TTL a zero."
if ip netns exec "$NS_CLIENT" ping -c 1 -W 2 -t 1 "$SERVER_IP"; then
    echo "Erreur : le paquet TTL=1 a atteint le serveur, ce qui est inattendu." >&2
    exit 1
else
    echo "Resultat attendu : le paquet expire sur le routeur."
fi

echo
echo "Test avec TTL=2 : le paquet peut franchir le routeur et atteindre le serveur."
ip netns exec "$NS_CLIENT" ping -c 1 -W 2 -t 2 "$SERVER_IP"

echo
echo "Conclusion : le forwarding fait transiter les paquets et chaque routeur decremente le TTL."
echo "Toute la topologie sera supprimee automatiquement."
