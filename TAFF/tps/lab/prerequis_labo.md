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

## Complément pour le TP3 uniquement

Installer avant la séance, dans la VM de laboratoire (en plus du socle ci-dessus) :

```bash
sudo apt install -y snmp snmpd softflowd nfdump iperf3
```

Sur Fedora, les noms et disponibilités des paquets de flux dépendent des dépôts :
préparer une image contenant `net-snmp`, `net-snmp-utils`, `softflowd`, `nfdump`
et `iperf3`, puis vérifier les exécutables ci-dessous. L'image Debian/Ubuntu est
le chemin de préparation documenté pour ce TP.

```bash
command -v snmpd snmpget snmpwalk softflowd nfcapd nfdump iperf3 tc
```

Les paquets sont nécessaires au **TP3 seulement** ; ils ne changent pas les
prérequis des TP1/TP2. Leurs éventuels services système ne sont pas utilisés
par la maquette. Le TP3 lance ses propres instances dans les namespaces `tp3_*`,
sans modifier `/etc/snmp`, les routes de l'hôte ou le filtrage des autres TP.

## Préparation distincte pour le TP5

Le TP5 requiert un hôte KVM/Libvirt/OVS et le
[kit Terraform/cloud-init/Ansible](libvirt_ovs/automation/README.md).
Terraform et le provider Libvirt **0.8.3** doivent être préchargés et verrouillés,
Ansible disponible sur le poste de contrôle, cloud-init présent dans l'image
Ubuntu préparée avec Python 3, SSH et les outils de test. Le réseau de management,
les réservations DHCP, le pool, l'image et le bridge OVS sont préparés avant la
séance. Ces dépendances ne sont pas requises par
les TP1–TP4 ; ne pas utiliser leur reset pour le TP5.

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

- Pour les maquettes TP1/TP2/VXLAN, utiliser leur reset commun avant de changer de topologie.
- Pour le TP3, utiliser exclusivement `sudo python3 supervision/lab.py reset --results tp3-resultats` ; ne pas lancer le reset commun. Les mesures sont conservées.
- Ne pas executer ces scripts sur une machine de production.
- Lire les scripts avant execution si la VM contient d'autres labs reseau.
