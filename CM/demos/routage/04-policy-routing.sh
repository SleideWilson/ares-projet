#!/usr/bin/env bash
set -euo pipefail

# Routage par politique : la source choisit une table, donc un chemin.

NS="ares-m2-r04-$$"
TAG="m2p04$(( $$ % 100000 ))"
IF_BLUE="${TAG}b"
IF_RED="${TAG}r"

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

printf '=== Routage par politique selon l adresse source ===\n'
printf 'Creation d un espace reseau temporaire : %s\n\n' "$NS"

ip netns add "$NS"
ip -n "$NS" link set lo up
ip -n "$NS" link add "$IF_BLUE" type dummy
ip -n "$NS" link add "$IF_RED" type dummy
ip -n "$NS" addr add 10.241.1.1/24 dev "$IF_BLUE"
ip -n "$NS" addr add 10.242.1.1/24 dev "$IF_RED"
ip -n "$NS" addr add 192.0.2.10/32 dev lo
ip -n "$NS" addr add 192.0.2.20/32 dev lo
ip -n "$NS" link set "$IF_BLUE" up
ip -n "$NS" link set "$IF_RED" up

# Deux tables contiennent une decision differente pour la meme destination.
ip -n "$NS" route add table 1041 203.0.113.0/24 dev "$IF_BLUE"
ip -n "$NS" route add table 1042 203.0.113.0/24 dev "$IF_RED"
ip -n "$NS" rule add priority 100 from 192.0.2.10/32 lookup 1041
ip -n "$NS" rule add priority 110 from 192.0.2.20/32 lookup 1042

printf '%s\n' 'Regles installees (priorite croissante) :'
ip -n "$NS" rule show
printf '\nTable 1041, chemin bleu :\n'
ip -n "$NS" route show table 1041
printf 'Table 1042, chemin rouge :\n'
ip -n "$NS" route show table 1042

printf '\nMeme destination, source 192.0.2.10 :\n'
BLUE_RESULT=$(ip -n "$NS" route get 203.0.113.42 from 192.0.2.10)
printf '  %s\n' "$BLUE_RESULT"

printf 'Meme destination, source 192.0.2.20 :\n'
RED_RESULT=$(ip -n "$NS" route get 203.0.113.42 from 192.0.2.20)
printf '  %s\n' "$RED_RESULT"

if [[ $BLUE_RESULT != *"dev $IF_BLUE"* || $RED_RESULT != *"dev $IF_RED"* ]]; then
    printf 'Erreur : les regles n ont pas selectionne les chemins attendus.\n' >&2
    exit 1
fi

printf '\nConclusion : ip rule choisit d abord la table grace a la source ;\n'
printf '             la table choisie fournit ensuite le chemin vers la destination.\n'
