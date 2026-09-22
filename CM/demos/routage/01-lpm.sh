#!/usr/bin/env bash
set -euo pipefail

readonly NS="m2-lpm-${BASHPID}"
readonly IF_8="m2l8${BASHPID}"
readonly IF_16="m2l16${BASHPID}"
readonly IF_24="m2l24${BASHPID}"

ns_created=0

cleanup() {
    local status=$?
    trap - EXIT INT TERM

    if (( ns_created )); then
        ip netns del "$NS" >/dev/null 2>&1 || true
    fi
    echo "FIN ! "
    exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if (( EUID != 0 )); then
    echo "Erreur : cette demonstration doit etre executee en root (utilisez sudo)." >&2
    exit 1
fi

if ! command -v ip >/dev/null 2>&1; then
    echo "Erreur : l'outil requis 'ip' est introuvable." >&2
    exit 1
fi

echo "=== Demonstration du Longest Prefix Match (LPM) ==="
echo "Creation d'un espace reseau isole : $NS"

ip netns add "$NS"
ns_created=1
ip -n "$NS" link set lo up

ip -n "$NS" link add "$IF_8" type dummy
ip -n "$NS" link add "$IF_16" type dummy
ip -n "$NS" link add "$IF_24" type dummy
ip -n "$NS" link set "$IF_8" up
ip -n "$NS" link set "$IF_16" up
ip -n "$NS" link set "$IF_24" up

ip -n "$NS" address add 192.0.2.8/32 dev "$IF_8"
ip -n "$NS" address add 192.0.2.16/32 dev "$IF_16"
ip -n "$NS" address add 192.0.2.24/32 dev "$IF_24"

ip -n "$NS" route add 10.0.0.0/8 dev "$IF_8" src 192.0.2.8
ip -n "$NS" route add 10.20.0.0/16 dev "$IF_16" src 192.0.2.16
ip -n "$NS" route add 10.20.30.0/24 dev "$IF_24" src 192.0.2.24

echo
echo "Routes concurrentes (plus le prefixe est long, plus la route est precise) :"
ip -n "$NS" -4 route show table main

show_lookup() {
    local destination=$1
    local expected=$2

    echo
    echo "Destination $destination : la route attendue est $expected"
    ip -n "$NS" -4 route get "$destination"
}

show_lookup 10.1.2.3 "10.0.0.0/8 via $IF_8"
show_lookup 10.20.2.3 "10.20.0.0/16 via $IF_16"
show_lookup 10.20.30.40 "10.20.30.0/24 via $IF_24"

echo
echo "Conclusion : 'ip route get' choisit toujours le prefixe correspondant le plus long."
echo "Le namespace sera supprime automatiquement."
