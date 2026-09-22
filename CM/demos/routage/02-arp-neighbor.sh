#!/usr/bin/env bash
set -euo pipefail

readonly NS_A="m2-arp-a-${BASHPID}"
readonly NS_B="m2-arp-b-${BASHPID}"
readonly IF_A="m2a${BASHPID}"
readonly IF_B="m2b${BASHPID}"
readonly IP_A="10.202.0.1"
readonly IP_B="10.202.0.2"

ns_a_created=0
ns_b_created=0

cleanup() {
    local status=$?
    trap - EXIT INT TERM

    if (( ns_a_created )); then
        ip netns del "$NS_A" >/dev/null 2>&1 || true
    fi
    if (( ns_b_created )); then
        ip netns del "$NS_B" >/dev/null 2>&1 || true
    fi

    # Ces suppressions couvrent aussi une erreur survenue avant le deplacement
    # des interfaces dans les namespaces.
    ip link del "$IF_A" >/dev/null 2>&1 || true
    ip link del "$IF_B" >/dev/null 2>&1 || true

    exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if (( EUID != 0 )); then
    echo "Erreur : cette demonstration doit etre executee en root (utilisez sudo)." >&2
    exit 1
fi

for tool in ip ping; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Erreur : l'outil requis '$tool' est introuvable." >&2
        exit 1
    fi
done

echo "=== Demonstration ARP et table des voisins ==="
echo "Creation de deux machines isolees reliees par une paire veth."

ip netns add "$NS_A"
ns_a_created=1
ip netns add "$NS_B"
ns_b_created=1

ip link add "$IF_A" type veth peer name "$IF_B"
ip link set "$IF_A" netns "$NS_A"
ip link set "$IF_B" netns "$NS_B"

ip -n "$NS_A" link set lo up
ip -n "$NS_B" link set lo up
ip -n "$NS_A" address add "$IP_A/24" dev "$IF_A"
ip -n "$NS_B" address add "$IP_B/24" dev "$IF_B"
ip -n "$NS_A" link set "$IF_A" up
ip -n "$NS_B" link set "$IF_B" up

# Garantit un etat initial reproductible, meme si le noyau a emis du trafic
# pendant la configuration.
ip -n "$NS_A" neigh flush dev "$IF_A" >/dev/null 2>&1 || true

echo
echo "1. Table des voisins de A avant tout trafic vers $IP_B :"
neighbors_before=$(ip -n "$NS_A" neigh show dev "$IF_A")
if [[ -n "$neighbors_before" ]]; then
    printf '%s\n' "$neighbors_before"
else
    echo "   (vide : aucune adresse MAC connue pour B)"
fi

echo
echo "2. Un ping force A a resoudre l'adresse IPv4 de B en adresse MAC :"
ip netns exec "$NS_A" ping -c 1 -W 2 "$IP_B"

echo
echo "3. Table des voisins de A apres le ping :"
ip -n "$NS_A" neigh show to "$IP_B" dev "$IF_A"

echo
echo "Conclusion : l'echange ARP a cree une entree dynamique dans la table des voisins."
echo "Les namespaces et interfaces seront supprimes automatiquement."
