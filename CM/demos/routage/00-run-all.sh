#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Exécutez avec les privilèges root : sudo $0" >&2
  exit 1
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

for demo in \
  01-lpm.sh \
  02-arp-neighbor.sh \
  03-forwarding-ttl.sh \
  04-policy-routing.sh \
  05-ecmp.sh \
  06-vrf.sh \
  07-nft-conntrack.sh \
  08-redondance-liens.sh \
  09-redondance-passerelles.sh \
  10-nat-filtrage.sh \
  11-rp-filter.sh; do
  printf '\n\n############################################################\n'
  printf '### %s\n' "$demo"
  printf '############################################################\n\n'
  DEMO_PAUSE=${DEMO_PAUSE:-1} "$script_dir/$demo"
done

echo
echo "Toutes les micro-démos se sont terminées avec succès."
