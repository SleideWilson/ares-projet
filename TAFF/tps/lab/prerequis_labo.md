# Prerequis labo

## Machine conseillee

- VM Linux recente, de preference Debian/Ubuntu/Fedora.
- 2 CPU, 4 Go RAM minimum.
- Acces root ou sudo.
- Connexion Internet seulement pour installer les paquets au debut.

## Paquets utiles

Debian/Ubuntu :

```bash
sudo apt update
sudo apt install -y iproute2 iputils-ping nftables conntrack tcpdump dnsmasq-base wireguard-tools python3
```

Fedora :

```bash
sudo dnf install -y iproute iputils nftables conntrack-tools tcpdump dnsmasq wireguard-tools python3
```

Optionnel :

```bash
sudo apt install -y frr prometheus grafana
sudo dnf install -y frr prometheus grafana
```

## Verification

```bash
ip -V
nft --version
conntrack -V
dnsmasq --version
python3 --version
wg --version
```

WireGuard est requis pour les manipulations du TP2 et optionnel pour les autres TP. Si `wg` est absent, utiliser les données VPN de `../../jeux_donnees/02_jeux_de_donnees.md` pour une analyse documentaire ; déclarer les essais non réalisés. Ce repli ne valide pas les manipulations du TP2.

## Regles d'exploitation

- Toujours lancer `sudo ./scripts/reset_lab.sh` avant de changer de TP technique.
- Ne pas executer ces scripts sur une machine de production.
- Lire les scripts avant execution si la VM contient d'autres labs reseau.
