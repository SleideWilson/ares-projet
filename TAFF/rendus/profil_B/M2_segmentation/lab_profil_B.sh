#!/usr/bin/env bash
set -euo pipefail

# M2 -- Profil B (Entreprise SaaS)
# Zones métier en VRF sur un routeur Linux, policy nftables stateful.
#
#   Couche 1 (routage) : une VRF par zone ; une zone ne connaît que les
#                        préfixes vers lesquels un flux est autorisé.
#   Couche 2 (filtrage) : nftables, policy drop, seuls les flux de la
#                        matrice M1 sont acceptés en état "new".
#
# Usage : sudo ./lab_profil_B.sh            (root)
#         unshare -Urnm --mount-proc ./lab_profil_B.sh   (sans root, voir README)

P=aresb
FW=$P-fw
ZONES=(admin users remote dc dmz cloud partner)

# zone -> passerelle/masque, hôte de test, table VRF
declare -A GW=(
  [admin]=10.40.250.1/24 [users]=10.40.10.1/23 [remote]=10.40.12.1/24
  [dc]=10.50.0.1/22 [dmz]=10.50.20.1/24 [cloud]=10.60.0.1/20
  [partner]=203.0.113.1/24
)
declare -A NET=(
  [admin]=10.40.250.0/24 [users]=10.40.10.0/23 [remote]=10.40.12.0/24
  [dc]=10.50.0.0/22 [dmz]=10.50.20.0/24 [cloud]=10.60.0.0/20
  [partner]=203.0.113.0/24
)
declare -A HOST=(
  [admin]=10.40.250.10 [users]=10.40.10.10 [remote]=10.40.12.10
  [dc]=10.50.0.10 [dmz]=10.50.20.10 [cloud]=10.60.0.10
  [partner]=203.0.113.10
)
declare -A TABLE=(
  [admin]=10 [users]=20 [remote]=30 [dc]=40 [dmz]=50 [cloud]=60 [partner]=70
)

# Matrice de flux M1 = policies de source_of_truth_cible.yaml.
# Format : "src dst ports"
FLOWS=(
  "admin users 22"
  "admin remote 22"
  "admin dc 22,443"
  "admin dmz 22,443"
  "admin cloud 22,443"
  "users dc 443"
  "users cloud 443"
  "remote dc 443"
  "remote cloud 443"
  "dc cloud 443"
  "dmz cloud 443"
  "partner dmz 443"
)
TEST_PORTS=(22 443)

LISTENER_PIDS=()
WORK=""

cleanup() {
  local pid
  for pid in "${LISTENER_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
  for z in "${ZONES[@]}"; do ip netns del "$P-$z" 2>/dev/null || true; done
  ip netns del "$FW" 2>/dev/null || true
  [[ -z $WORK ]] || rm -rf "$WORK"
}

pause() {
  if [[ ${DEMO_PAUSE:-0} != 0 && -t 0 ]]; then
    read -r -p "Appuyez sur Entrée pour continuer... " _
  fi
}

section() { printf '\n=== %s ===\n' "$1"; }

if (( EUID != 0 )); then
  echo "Exécutez avec les privilèges root : sudo $0" >&2
  exit 1
fi
for c in ip nft python3 timeout; do
  command -v "$c" >/dev/null 2>&1 || { echo "Commande requise absente : $c" >&2; exit 1; }
done

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cleanup
WORK=$(mktemp -d)

# --------------------------------------------------------------------------
section "1. Construction : un routeur $FW, une VRF et un hôte par zone"

ip netns add "$FW"
ip -n "$FW" link set lo up
ip netns exec "$FW" sysctl -qw net.ipv4.ip_forward=1

for z in "${ZONES[@]}"; do
  ns=$P-$z
  ip netns add "$ns"
  ip -n "$ns" link set lo up

  ip -n "$FW" link add "vrf-$z" type vrf table "${TABLE[$z]}"
  ip -n "$FW" link set "vrf-$z" up
  # Sans route, la recherche ne doit pas retomber dans la table main.
  ip -n "$FW" route add unreachable default metric 4278198272 table "${TABLE[$z]}"

  ip link add "fw-$z" netns "$FW" type veth peer name eth0 netns "$ns"
  ip -n "$FW" link set "fw-$z" master "vrf-$z"
  ip -n "$FW" addr add "${GW[$z]}" dev "fw-$z"
  ip -n "$FW" link set "fw-$z" up

  ip -n "$ns" addr add "${HOST[$z]}/${GW[$z]#*/}" dev eth0
  ip -n "$ns" link set eth0 up
  ip -n "$ns" route add default via "${GW[$z]%/*}"

  printf '  %-8s %-16s hôte %-13s VRF vrf-%-8s table %s\n' \
    "$z" "${NET[$z]}" "${HOST[$z]}" "$z" "${TABLE[$z]}"
done

# --------------------------------------------------------------------------
section "2. Fuite de routes inter-VRF limitée aux flux autorisés"

leak() { # leak <zone qui reçoit la route> <zone de destination>
  ip -n "$FW" route replace "${NET[$2]}" dev "fw-$2" table "${TABLE[$1]}"
}
for f in "${FLOWS[@]}"; do
  read -r src dst _ <<<"$f"
  leak "$src" "$dst"   # aller
  leak "$dst" "$src"   # retour (symétrie)
done

echo "Table de la VRF partner : le partenaire ne connaît que la DMZ API."
ip -n "$FW" route show table "${TABLE[partner]}"
echo
echo "Table de la VRF admin : l'administration connaît toutes les zones sauf partner."
ip -n "$FW" route show table "${TABLE[admin]}"
echo
echo "Décision partner -> DMZ API :"
ip -n "$FW" route get "${HOST[dmz]}" from "${HOST[partner]}" iif fw-partner
echo "Décision partner -> admin :"
ip -n "$FW" route get "${HOST[admin]}" from "${HOST[partner]}" iif fw-partner 2>&1 || true
pause

# --------------------------------------------------------------------------
section "3. Policy nftables générée depuis la matrice de flux"

{
  echo "table inet $P {"
  echo "  chain prerouting {"
  echo "    type filter hook prerouting priority raw; policy accept;"
  echo "    # anti-usurpation : chaque zone n'émet que depuis son préfixe"
  for z in "${ZONES[@]}"; do
    echo "    iifname \"fw-$z\" ip saddr != ${NET[$z]} counter drop comment \"spoof-$z\""
  done
  echo "  }"
  echo "  chain forward {"
  echo "    type filter hook forward priority filter; policy drop;"
  echo "    ct state established,related counter accept"
  echo "    ct state invalid counter drop"
  for f in "${FLOWS[@]}"; do
    read -r src dst ports <<<"$f"
    echo "    ip saddr ${NET[$src]} ip daddr ${NET[$dst]} tcp dport { $ports } ct state new counter accept comment \"$src-to-$dst\""
  done
  echo "    counter comment \"default-deny\""
  echo "  }"
  echo "}"
} > "$WORK/ruleset.nft"
ip netns exec "$FW" nft -f "$WORK/ruleset.nft"
ip netns exec "$FW" nft list chain inet "$P" forward
pause

# --------------------------------------------------------------------------
section "4. Services de test (tcp/22 et tcp/443) dans chaque zone"

for z in "${ZONES[@]}"; do
  ip netns exec "$P-$z" python3 - "${TEST_PORTS[@]}" <<'EOF' &
import socket, sys, threading
def serve(port):
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("0.0.0.0", port)); s.listen(64)
    while True:
        c, _ = s.accept(); c.close()
for p in sys.argv[1:]:
    threading.Thread(target=serve, args=(int(p),), daemon=True).start()
threading.Event().wait()
EOF
  LISTENER_PIDS+=($!)
done
sleep 1
echo "Écoute active sur tcp/${TEST_PORTS[*]} dans les ${#ZONES[@]} zones."

# --------------------------------------------------------------------------
# probe <src> <dst> <port> -> OK | -- (timeout ou refus)
probe() {
  if ip netns exec "$P-$1" timeout 1.5 bash -c "exec 3<>/dev/tcp/${HOST[$2]}/$3" 2>/dev/null; then
    echo OK
  else
    echo --
  fi
}

counter_of() { # counter_of <commentaire de règle> -> paquets comptés
  ip netns exec "$FW" nft list ruleset |
    sed -n "s/.*counter packets \([0-9]*\).*comment \"$1\".*/\1/p"
}

expected() { # expected <src> <dst> <port> -> OK | --
  local f src dst ports
  for f in "${FLOWS[@]}"; do
    read -r src dst ports <<<"$f"
    if [[ $src == "$1" && $dst == "$2" && ,$ports, == *",$3,"* ]]; then echo OK; return; fi
  done
  echo --
}

run_matrix() {
  local src dst port errors=0 pids=()
  for src in "${ZONES[@]}"; do for dst in "${ZONES[@]}"; do
    [[ $src == "$dst" ]] && continue
    for port in "${TEST_PORTS[@]}"; do
      probe "$src" "$dst" "$port" > "$WORK/r-$src-$dst-$port" &
      pids+=($!)
    done
  done; done
  wait "${pids[@]}"

  printf '%-9s' 'src\dst'
  for dst in "${ZONES[@]}"; do printf '%-10s' "$dst"; done
  printf '\n'
  for src in "${ZONES[@]}"; do
    printf '%-9s' "$src"
    for dst in "${ZONES[@]}"; do
      if [[ $src == "$dst" ]]; then printf '%-10s' '·'; continue; fi
      local cell=""
      for port in "${TEST_PORTS[@]}"; do
        local got want
        got=$(<"$WORK/r-$src-$dst-$port"); want=$(expected "$src" "$dst" "$port")
        if [[ $got == OK ]]; then cell+="$port "; fi
        if [[ $got != "$want" ]]; then cell+="!"; errors=$((errors + 1)); fi
      done
      printf '%-10s' "${cell:--}"
    done
    printf '\n'
  done
  echo "(cellule = ports TCP ouverts ; '-' = tout bloqué ; '!' = écart avec la matrice M1)"
  return "$errors"
}

section "5. Validation : matrice observée vs matrice M1 (${#ZONES[@]}x${#ZONES[@]} zones, tcp/22 et 443)"
if run_matrix; then
  echo "RÉSULTAT : 0 écart, la policy appliquée est conforme à la matrice M1."
else
  echo "RÉSULTAT : écarts détectés." >&2
  exit 1
fi

echo
echo "Compteurs nftables après le test :"
ip netns exec "$FW" nft list chain inet "$P" forward | grep -E 'counter packets [1-9]'
if command -v conntrack >/dev/null 2>&1; then
  echo
  echo "Table conntrack du routeur :"
  ip netns exec "$FW" conntrack -L -p tcp 2>/dev/null | head -20 || true
fi
pause

# --------------------------------------------------------------------------
section "6. Panne A : erreur de routage, une route partner -> admin fuit"

ip -n "$FW" route replace "${NET[admin]}" dev fw-admin table "${TABLE[partner]}"
ip -n "$FW" route replace "${NET[partner]}" dev fw-partner table "${TABLE[admin]}"
echo "Route ajoutée par erreur : $(ip -n "$FW" route show table "${TABLE[partner]}" "${NET[admin]}")"
before=$(counter_of default-deny)
res22=$(probe partner admin 22); res443=$(probe partner admin 443)
after=$(counter_of default-deny)
echo "partner -> admin tcp/22 : $res22 ; tcp/443 : $res443"
echo "Compteur default-deny : $before -> $after paquets"
if [[ $res22 != -- || $res443 != -- || $after -le $before ]]; then
  echo "ERREUR : le filtrage aurait dû bloquer et compter ces paquets." >&2
  exit 1
fi
echo "Conclusion : le routage seul ne protège pas ; nftables bloque quand même (défense en profondeur)."
ip -n "$FW" route del "${NET[admin]}" table "${TABLE[partner]}"
ip -n "$FW" route del "${NET[partner]}" table "${TABLE[admin]}"
pause

# --------------------------------------------------------------------------
section "7. Attaque : le partenaire usurpe une adresse admin"

# Sans anti-usurpation, la règle admin-to-dmz accepterait ce SYN.
ip -n "$P-partner" addr add 10.40.250.99/32 dev eth0
before=$(counter_of spoof-partner)
if ip netns exec "$P-partner" timeout 2 python3 -c '
import socket, sys
s = socket.socket(); s.settimeout(1); s.bind(("10.40.250.99", 0))
s.connect((sys.argv[1], 443))' "${HOST[dmz]}" 2>/dev/null; then resS=OK; else resS=--; fi
after=$(counter_of spoof-partner)
echo "partner (source usurpée 10.40.250.99) -> dmz tcp/443 : $resS"
echo "Compteur spoof-partner : $before -> $after paquets (rejet en prerouting)"
if [[ $resS != -- || $after -le $before ]]; then
  echo "ERREUR : l'usurpation aurait dû être bloquée en prerouting." >&2
  exit 1
fi
ip -n "$P-partner" addr del 10.40.250.99/32 dev eth0
echo "Conclusion : une policy fondée sur les adresses exige un contrôle de la source par interface."
pause

# --------------------------------------------------------------------------
section "8. Panne B : route retour DMZ -> partner absente (asymétrie)"

ip -n "$FW" route del "${NET[partner]}" table "${TABLE[dmz]}"
echo "Aller  : $(ip -n "$FW" route get "${HOST[dmz]}" from "${HOST[partner]}" iif fw-partner | head -1)"
echo "Retour : $(ip -n "$FW" route get "${HOST[partner]}" from "${HOST[dmz]}" iif fw-dmz 2>&1 | head -1)"
if command -v tcpdump >/dev/null 2>&1; then
  ip netns exec "$FW" timeout 3 tcpdump -Z root -lni fw-dmz -c 4 tcp port 443 2>/dev/null > "$WORK/cap" &
  cap_pid=$!
  sleep 0.5
fi
resB=$(probe partner dmz 443)
if [[ -n ${cap_pid:-} ]]; then
  wait "$cap_pid" 2>/dev/null || true
  echo "Capture sur fw-dmz (le SYN-ACK de l'API arrive mais ne repart pas vers le partenaire) :"
  sed 's/^/  /' "$WORK/cap"
fi
echo "partner -> dmz tcp/443 sans route retour : $resB"
[[ $resB == -- ]] || { echo "ERREUR : la connexion aurait dû échouer." >&2; exit 1; }

echo "Correction : rétablir la route retour dans la VRF dmz."
leak dmz partner
resB2=$(probe partner dmz 443)
echo "partner -> dmz tcp/443 après correction : $resB2"
[[ $resB2 == OK ]] || { echo "ERREUR : la connexion devrait être rétablie." >&2; exit 1; }

section "9. Validation après correction"
if ! run_matrix; then
  echo "RÉSULTAT : écarts détectés après correction." >&2
  exit 1
fi
echo "RÉSULTAT : 0 écart après correction."

echo
echo "Conclusion : la VRF limite les chemins, nftables limite les flux, conntrack"
echo "laisse passer les réponses, et chaque flux exige une route aller ET retour."
