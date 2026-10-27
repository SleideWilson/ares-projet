# M2 -- Design dataplane et preuves de forwarding -- Profil B (Entreprise SaaS)

Livrable : appliquer réellement sur un dataplane Linux les zones et la matrice de
flux décidées en M1, puis prouver le chemin, la symétrie et la policy.

- Script : [`lab_profil_B.sh`](lab_profil_B.sh)
- Sortie complète : [`preuves/execution_lab_profil_B.txt`](preuves/execution_lab_profil_B.txt)

## 1. Contexte donné

- **Profil de groupe** : B -- Entreprise SaaS.
- **État ARESlabs de départ** : la sortie du M1 (zones, plan IP corrigé, matrice
  de flux), reportée dans
  [`source_of_truth_cible.yaml`](../../../projet/source_of_truth_cible.yaml).
  Les VRF `users`, `remote` et `partner` sont ajoutées, ainsi que les 16
  policies. Le dataplane n'applique encore aucune politique.
- **Contraintes imposées** :
  - le partenaire n'accède qu'à une application ;
  - l'administration passe uniquement par la zone Admin ;
  - l'outillage est Linux standard (iproute2, nftables), sans équipement
    dédié.
- **Données reçues** : plan IP du profil B, matrice de flux M1, démos du cours
  (`06-vrf.sh`, `07-nft-conntrack.sh`, `11-rp-filter.sh`). _Ajouter ici les
  données distribuées en séance._
- **Hypothèses ajoutées** :
  - H7 : un seul routeur Linux joue le rôle de point de contrôle entre toutes
    les zones. Dans ARESlabs, ce rôle est porté par `vm1-router` et
    `vm2-router`.
  - H8 : chaque zone est représentée par un namespace contenant un hôte de
    test qui écoute sur tcp/22 et tcp/443.

## 2. Décision retenue

**Décision** : **une VRF par zone sur le routeur, une fuite de routes limitée
aux flux autorisés, et une policy nftables stateful par défaut `drop`.** La
policy est générée depuis la même matrice que la source de vérité.

Deux couches indépendantes :

| Couche | Mécanisme | Ce qu'elle garantit |
| --- | --- | --- |
| Routage | VRF + routes « fuitées » uniquement pour les couples autorisés | Une zone **ne connaît pas** les préfixes qu'elle n'a pas le droit de joindre |
| Filtrage | nftables `forward` policy `drop`, règles `ct state new` par couple et par port | Seuls les **ports** autorisés passent, même si une route existe par erreur |
| Anti-usurpation | nftables `prerouting` : chaque interface de zone n'accepte que son préfixe source | Les règles fondées sur l'adresse source ne peuvent pas être contournées |

Le placement suit le chemin du paquet :

```
prerouting (raw) : anti-usurpation par interface
   → décision de routage dans la table de la VRF d'entrée
   → forward (filter) : conntrack + matrice de flux
   → sortie
```

Il n'y a **pas de NAT** entre zones internes. Les adresses restent visibles de
bout en bout, ce qui est nécessaire pour la journalisation des accès admin.

**Alternatives rejetées** :

- **Alternative 1** : une seule table de routage et le filtrage nftables
  seul.
  - **Pourquoi rejetée** : une seule erreur de règle ouvre l'accès, car tous
    les préfixes sont routables depuis toutes les zones. Avec les VRF, le
    partenaire n'a même pas de route vers Admin (preuve 1). Il faut donc deux
    erreurs indépendantes pour ouvrir un flux.
- **Alternative 2** : les VRF seules, sans pare-feu (les routes servent de
  politique).
  - **Pourquoi rejetée** : une route ouvre **tous les ports** d'un préfixe.
    `users → cloud` ne doit autoriser que tcp/443, ce que le routage ne sait
    pas exprimer. Une route ajoutée par erreur ouvrirait aussi tout (panne A).
- **Alternative 3** : des ACL sans état (`iptables`, sans conntrack).
  - **Pourquoi rejetée** : il faudrait ouvrir explicitement les retours
    (ports éphémères), ce qui double les règles et ouvre des ports hauts dans
    l'autre sens. Le cours (démo 07) montre que conntrack résout ce problème
    proprement.

## 3. Justification

**Exigences concernées** :

- **Disponibilité** : la policy est vérifiée automatiquement (matrice 7×7).
  Une régression de configuration est donc détectée avant d'affecter l'API
  (SLO 99,9 %).
- **Sécurité** :
  - le partenaire n'atteint que `dmz:443` (exigence « une application ») ;
  - la DMZ ne peut rien initier vers l'interne, seulement vers le back-end
    Cloud ;
  - l'usurpation de source est bloquée.
- **Performance** : le filtrage stateful ne traite que le premier paquet de
  chaque connexion. Les suivants passent par la règle
  `established,related`, la première de la chaîne (79 paquets contre 15
  « new » pendant le test).
- **Exploitabilité** : la policy est **générée** depuis le tableau `FLOWS`,
  qui reprend les policies de la source de vérité. Une règle porte le nom de
  la policy (`comment "partner-to-dmz"`) et son compteur, ce qui rend le
  diagnostic direct.
- **Coût** : aucun équipement. iproute2 et nftables sont présents sur les
  routeurs ARESlabs.

**Flux concernés** (extraits ; la matrice complète est en preuve 2) :

| Source | Destination | Service/protocole | Criticité | Contrôle attendu |
| --- | --- | --- | --- | --- |
| Partenaire `203.0.113.0/24` | DMZ API `10.50.20.0/24` | tcp/443 | Haute | VRF partner = route DMZ seule ; règle `partner-to-dmz` |
| DMZ API | Cloud Prod `10.60.0.0/20` | tcp/443 | Haute (chemin de l'API) | Règle `dmz-to-cloud`, aucun autre flux sortant |
| Admin `10.40.250.0/24` | Toutes les zones sauf partner | tcp/22, tcp/443 | Haute | Règles `admin-to-*`, aucun flux entrant vers Admin |
| Users / Remote | DC, Cloud | tcp/443 | Moyenne | Règles `users-to-*`, `remote-to-*` |

## 4. Architecture proposée

**Évolution apportée à ARESlabs depuis M1** : la matrice de flux est passée du
document au dataplane. La source de vérité contient désormais les zones du
profil B.

### Table zone / VRF / interface

| Zone | Préfixe | VRF (table) | Interface routeur | Passerelle | Hôte de test |
| --- | --- | --- | --- | --- | --- |
| admin | `10.40.250.0/24` | `vrf-admin` (10) | `fw-admin` | `.1` | `10.40.250.10` |
| users | `10.40.10.0/23` | `vrf-users` (20) | `fw-users` | `.1` | `10.40.10.10` |
| remote | `10.40.12.0/24` | `vrf-remote` (30) | `fw-remote` | `.1` | `10.40.12.10` |
| dc | `10.50.0.0/22` | `vrf-dc` (40) | `fw-dc` | `.1` | `10.50.0.10` |
| dmz | `10.50.20.0/24` | `vrf-dmz` (50) | `fw-dmz` | `.1` | `10.50.20.10` |
| cloud | `10.60.0.0/20` | `vrf-cloud` (60) | `fw-cloud` | `.1` | `10.60.0.10` |
| partner | `203.0.113.0/24` | `vrf-partner` (70) | `fw-partner` | `.1` | `203.0.113.10` |

Chaque table VRF se termine par `unreachable default metric 4278198272`. Cette
route empêche une recherche qui échoue dans une VRF de retomber dans la table
`main`, comme le recommande la documentation noyau des VRF.

### Règle de fuite de routes

Pour chaque flux `src → dst` autorisé :

- le préfixe `dst` est ajouté dans la table de `src` (aller) ;
- le préfixe `src` est ajouté dans la table de `dst` (retour).

Aucune autre route inter-VRF n'existe.

### Policy nftables (extrait)

```
chain prerouting { type filter hook prerouting priority raw; policy accept;
  iifname "fw-partner" ip saddr != 203.0.113.0/24 counter drop comment "spoof-partner"
  ... (une règle par zone)
}
chain forward { type filter hook forward priority filter; policy drop;
  ct state established,related counter accept
  ct state invalid counter drop
  ip saddr 203.0.113.0/24 ip daddr 10.50.20.0/24 tcp dport 443 ct state new counter accept comment "partner-to-dmz"
  ... (une règle par flux de la matrice)
  counter comment "default-deny"
}
```

### Correspondance avec ARESlabs

Dans la maquette ARESlabs, les zones sont réparties sur deux routeurs :

- `vm1-router` porte users, remote, admin et dc ;
- `vm2-router` porte dmz et partner (exposition) ;
- `cloud-gw` porte cloud.

Le même modèle VRF + nftables s'applique sur chaque routeur. Les VRF sont
transportées entre sites par le tunnel, qui sera chiffré en M4 ; la
segmentation de bout en bout via VXLAN/EVPN avec une VNI par VRF est traitée
en M7.

## 5. Preuves

Toutes les preuves viennent de
[`preuves/execution_lab_profil_B.txt`](preuves/execution_lab_profil_B.txt)
(noyau 6.17, code retour 0).

**Preuve 1 -- Le partenaire n'a pas de chemin vers l'administration**

- **Observation** :
  ```
  $ ip route show table 70        # vrf-partner
  10.50.20.0/24 dev fw-dmz scope link
  203.0.113.0/24 dev fw-partner proto kernel scope link src 203.0.113.1
  $ ip route get 10.40.250.10 from 203.0.113.10 iif fw-partner
  RTNETLINK answers: No route to host
  $ ip route get 10.50.20.10 from 203.0.113.10 iif fw-partner
  10.50.20.10 from 203.0.113.10 dev fw-dmz table 70
  ```
- **Interprétation** : la VRF partner ne contient que son propre préfixe et la
  DMZ API. L'exigence « accès partenaire limité à une application » est déjà
  appliquée au niveau du routage.
- **Impact architectural** : le filtrage nftables devient une deuxième
  barrière et non la seule.

**Preuve 2 -- La matrice observée est identique à la matrice M1**

- **Observation** : on teste les 84 combinaisons (7 zones × 6 destinations ×
  2 ports) par une vraie connexion TCP :
  ```
  src\dst  admin     users     remote    dc        dmz       cloud     partner
  admin    ·         22        22        22 443    22 443    22 443    -
  users    -         ·         -         443       -         443       -
  remote   -         -         ·         443       -         443       -
  dc       -         -         -         ·         -         443       -
  dmz      -         -         -         -         ·         443       -
  cloud    -         -         -         -         -         ·         -
  partner  -         -         -         -         443       -         ·
  RÉSULTAT : 0 écart, la policy appliquée est conforme à la matrice M1.
  ```
- **Interprétation** : chaque cellule est comparée à la matrice M1. Aucun
  flux autorisé n'est bloqué et aucun flux non autorisé ne passe. La colonne
  admin est entièrement bloquée (aucun flux entrant vers l'administration),
  de même que la ligne cloud.
- **Impact architectural** : ce test devient le **test de non-régression**
  de la policy, à réutiliser dans le pipeline M8.

**Preuve 3 -- Les compteurs prouvent quelle règle a décidé**

- **Observation** :
  ```
  ct state established,related counter packets 79 ... accept
  ip saddr 203.0.113.0/24 ip daddr 10.50.20.0/24 tcp dport 443 ct state new counter packets 1 ... comment "partner-to-dmz"
  counter packets 66 ... comment "default-deny"
  ```
- **Interprétation** : chaque flux autorisé a été accepté par **sa** règle
  (1 paquet « new » par port testé, 15 flux autorisés), puis ses réponses par
  conntrack. Sur les 69 tentatives interdites :
  - **36 échouent dès le routage** : il n'existe aucune route entre les deux
    zones ;
  - **33 sont refusées par nftables** : une route existe, car la zone de
    destination a un flux vers la source, mais pas dans ce sens ni sur ce
    port. Par exemple `cloud → admin` utilise la route retour de
    `admin → cloud`.

  Chaque tentative refusée compte 2 paquets (SYN et une retransmission), soit
  66 paquets.
- **Impact architectural** : en exploitation, un compteur `default-deny` qui
  augmente est un signal de mauvaise configuration ou d'attaque. C'est une
  métrique à superviser en M5.

## 6. Scénario de panne

### Panne A -- Une route partner → admin est ajoutée par erreur

- **Incident testé** : `ip route replace 10.40.250.0/24 dev fw-admin table 70`,
  plus la route retour.
- **Impact attendu** : la couche routage est contournée.
- **Comportement de l'architecture** : `partner → admin` tcp/22 et tcp/443
  restent **bloqués**. Le compteur `default-deny` passe de 66 à 70 paquets.
  nftables compense l'erreur de routage.
- **Correction minimale** : supprimer la route. En M8, un test vérifie que
  les routes inter-VRF correspondent exactement aux policies de la source de
  vérité.
- **Validation après correction** : la matrice repasse avec 0 écart.

### Attaque -- Le partenaire usurpe une adresse admin

- **Incident testé** : l'hôte partenaire émet depuis `10.40.250.99` vers
  `dmz:443`.
- **Impact attendu** : sans contrôle de la source, la règle `admin-to-dmz`
  (tcp/443) **accepterait** ce SYN, car il arrive dans la VRF partner, qui a
  une route vers la DMZ.
- **Comportement de l'architecture** : le paquet est rejeté en `prerouting`.
  Le compteur `spoof-partner` passe de 0 à 2 paquets (SYN et retransmission)
  et la connexion échoue.
- **Leçon** : une policy fondée sur les adresses n'a de valeur que si la
  source est vérifiée **par interface d'entrée**.

### Panne B -- Route retour DMZ → partenaire absente (asymétrie)

- **Incident testé** : suppression de `203.0.113.0/24` dans la table de
  `vrf-dmz`.
- **Impact attendu** : l'aller fonctionne et le retour est impossible.
- **Comportement de l'architecture** :
  ```
  Aller  : 10.50.20.10 from 203.0.113.10 dev fw-dmz table 70
  Retour : RTNETLINK answers: No route to host
  IP 203.0.113.10.35004 > 10.50.20.10.443: Flags [S]
  IP 10.50.20.10.443 > 203.0.113.10.35004: Flags [S.]
  IP 203.0.113.10.35004 > 10.50.20.10.443: Flags [S]      (retransmission)
  ```
  Le serveur API **répond** (SYN-ACK visible sur `fw-dmz`), mais la réponse
  ne repart jamais vers le partenaire. Les logs de l'API montrent des
  connexions reçues, alors que le partenaire voit des timeouts. C'est le
  symptôme typique d'une asymétrie.
- **Correction minimale** : rétablir la route retour (`leak dmz partner`).
  Chaque flux est désormais déclaré une seule fois et génère automatiquement
  l'aller et le retour.
- **Validation après correction** : `partner → dmz:443` répond OK et la
  matrice complète repasse avec **0 écart** (section 9 de la sortie).

## 7. Limites

- **Limite connue 1** : un seul routeur concentre toutes les zones. C'est un
  point unique de panne et le prototype ne reflète pas la répartition
  ARESlabs (deux routeurs reliés par un tunnel). Avec plusieurs routeurs, la
  symétrie devient plus délicate, car conntrack exige que l'aller et le
  retour passent par le **même** pare-feu. À traiter avec la redondance des
  passerelles, par exemple VRRP plus `conntrackd` (démo 09).
- **Limite connue 2** : la zone Internet et le NAT sortant (Users → Internet,
  Admin → mises à jour) prévus en M1 ne sont pas modélisés. Il manque aussi la
  journalisation des acceptations admin. Une règle `log` ne s'affiche pas
  depuis un namespace sans `nf_log_all_netns`, donc la journalisation exigée
  par le profil passera par le bastion et une collecte centralisée (M4/M5),
  pas par le pare-feu seul.
- **Limite connue 3** : le test a été exécuté dans un namespace utilisateur
  (`unshare -Urnm`), sans root. Le comportement noyau est le même, mais il
  faut le rejouer avec `sudo` sur la maquette ARESlabs pour la soutenance.
- **Évolution proposée** :
  - M3 : DHCP pour `users`/`remote` avec relais par VRF, DNS accessible depuis
    toutes les zones (flux à ajouter à la matrice) ;
  - M4 : chiffrement du lien entre routeurs, bastion MFA journalisé ;
  - M8 : générer `FLOWS` directement depuis `source_of_truth_cible.yaml` et
    lancer la matrice en CI.

## Rejouer les preuves

```bash
# Sur la maquette (root) :
sudo ./lab_profil_B.sh | tee preuves/execution_lab_profil_B.txt
# Mode pas à pas pour la démonstration :
sudo DEMO_PAUSE=1 ./lab_profil_B.sh

# Sans root (poste personnel, noyau avec VRF et nftables) :
unshare -Urnm bash -c 'mount -t tmpfs tmpfs /run && mkdir -p /run/netns && ./lab_profil_B.sh'
```
