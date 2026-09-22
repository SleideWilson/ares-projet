#!/usr/bin/env bash
set -euo pipefail

# ECMP : plusieurs nexthops de cout egal, choisis par hachage de flux.

NS="ares-m2-r05-$$"
TAG="m2e05$(( $$ % 100000 ))"
IF_A="${TAG}a"
IF_B="${TAG}b"

cleanup() {
    ip netns del "$NS" >/dev/null 2>&1 || true
}

on_signal() {
    local status=$1
    exit "$status"
}

trap cleanup EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

if (( EUID != 0 )); then
    printf 'Erreur : cette demonstration doit etre executee en root.\n' >&2
    exit 1
fi

if ! command -v ip >/dev/null 2>&1; then
    printf 'Erreur : la commande "ip" (paquet iproute2) est requise.\n' >&2
    exit 1
fi

route_device() {
    local destination=$1
    local result

    result=$(ip -n "$NS" route get "$destination" from 192.0.2.10)
    if [[ $result =~ (^|[[:space:]])dev[[:space:]]+([^[:space:]]+) ]]; then
        printf '%s' "${BASH_REMATCH[2]}"
        return 0
    fi

    printf 'Erreur : interface absente du resultat "%s".\n' "$result" >&2
    return 1
}

printf '=== ECMP : stabilite par flux et repartition entre flux ===\n'
printf 'Creation d un espace reseau temporaire : %s\n\n' "$NS"

ip netns add "$NS"
ip -n "$NS" link set lo up
ip -n "$NS" link add "$IF_A" type dummy
ip -n "$NS" link add "$IF_B" type dummy
ip -n "$NS" addr add 10.251.1.1/24 dev "$IF_A"
ip -n "$NS" addr add 10.252.1.1/24 dev "$IF_B"
ip -n "$NS" addr add 192.0.2.10/32 dev lo
ip -n "$NS" link set "$IF_A" up
ip -n "$NS" link set "$IF_B" up

ip -n "$NS" route add 203.0.113.0/24 \
    nexthop via 10.251.1.2 dev "$IF_A" weight 1 \
    nexthop via 10.252.1.2 dev "$IF_B" weight 1

printf '%s\n' 'Route multipath installee :'
ip -n "$NS" route show 203.0.113.0/24

printf '\nUn meme flux garde le meme nexthop :\n'
REFERENCE=$(route_device 203.0.113.42)
for attempt in 1 2 3; do
    CHOICE=$(route_device 203.0.113.42)
    printf '  essai %d, 192.0.2.10 -> 203.0.113.42 : %s\n' \
        "$attempt" "$CHOICE"
    if [[ $CHOICE != "$REFERENCE" ]]; then
        printf 'Erreur : le choix ECMP du meme flux n est pas stable.\n' >&2
        exit 1
    fi
done

printf '\nDes destinations differentes representent des flux differents :\n'
declare -A SEEN=()
for host in {1..64}; do
    DESTINATION="203.0.113.${host}"
    CHOICE=$(route_device "$DESTINATION")
    SEEN["$CHOICE"]=1
    if (( host <= 12 )); then
        printf '  192.0.2.10 -> %-15s : %s\n' "$DESTINATION" "$CHOICE"
    fi
done

if (( ${#SEEN[@]} < 2 )); then
    printf 'Erreur : le noyau n a selectionne qu un seul nexthop pour 64 flux.\n' >&2
    exit 1
fi

printf '\nLes %d nexthops ont ete observes. ECMP repartit les flux, pas les paquets\n' \
    "${#SEEN[@]}"
printf 'd un meme flux : cela limite le reordonnancement des paquets.\n'
