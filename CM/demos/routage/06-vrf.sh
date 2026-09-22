#!/usr/bin/env bash
set -euo pipefail

# VRF : deux domaines de routage independants peuvent reutiliser les memes IP.

NS="ares-m2-r06-$$"
TAG="m2v06$(( $$ % 100000 ))"
VRF_BLUE="${TAG}vb"
VRF_RED="${TAG}vr"
IF_BLUE="${TAG}ib"
IF_RED="${TAG}ir"

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

printf '=== VRF : tables separees et prefixes qui se chevauchent ===\n'
printf 'Creation d un espace reseau temporaire : %s\n\n' "$NS"

ip netns add "$NS"
ip -n "$NS" link set lo up

if ! ip -n "$NS" link add "$VRF_BLUE" type vrf table 1061; then
    printf 'Erreur : ce noyau ne prend pas en charge les interfaces VRF.\n' >&2
    exit 1
fi
ip -n "$NS" link add "$VRF_RED" type vrf table 1062
ip -n "$NS" link add "$IF_BLUE" type dummy
ip -n "$NS" link add "$IF_RED" type dummy

ip -n "$NS" link set "$IF_BLUE" master "$VRF_BLUE"
ip -n "$NS" link set "$IF_RED" master "$VRF_RED"
ip -n "$NS" addr add 10.66.0.1/24 dev "$IF_BLUE"
ip -n "$NS" addr add 10.66.0.1/24 dev "$IF_RED"
ip -n "$NS" link set "$VRF_BLUE" up
ip -n "$NS" link set "$VRF_RED" up
ip -n "$NS" link set "$IF_BLUE" up
ip -n "$NS" link set "$IF_RED" up

printf '%s\n' 'Deux VRF reutilisent exactement le prefixe 10.66.0.0/24 :'
printf '  %-18s table 1061, interface %s\n' "$VRF_BLUE" "$IF_BLUE"
printf '  %-18s table 1062, interface %s\n' "$VRF_RED" "$IF_RED"

printf '\nTable de la VRF bleue :\n'
ip -n "$NS" route show table 1061
printf 'Table de la VRF rouge :\n'
ip -n "$NS" route show table 1062

printf '\nDecision pour 10.66.0.42 dans la VRF bleue :\n'
BLUE_RESULT=$(ip -n "$NS" route get 10.66.0.42 from 10.66.0.1 vrf "$VRF_BLUE")
printf '  %s\n' "$BLUE_RESULT"

printf 'Decision pour la meme adresse dans la VRF rouge :\n'
RED_RESULT=$(ip -n "$NS" route get 10.66.0.42 from 10.66.0.1 vrf "$VRF_RED")
printf '  %s\n' "$RED_RESULT"

if [[ $BLUE_RESULT != *"dev $IF_BLUE"* || $RED_RESULT != *"dev $IF_RED"* ]]; then
    printf 'Erreur : les VRF n ont pas selectionne leurs interfaces respectives.\n' >&2
    exit 1
fi

printf '\nConclusion : une VRF associe les interfaces a une table de routage.\n'
printf 'Le meme prefixe peut donc conduire a deux decisions independantes.\n'
