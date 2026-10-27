# M1 -- Dossier de cadrage -- Profil B (Entreprise SaaS)

Groupe : _à compléter_

## 1. Contexte donné

- **Profil de groupe** : B -- Entreprise SaaS.
  - Siège Lyon : 250 utilisateurs.
  - Datacenter privé : 120 serveurs.
  - Cloud public : production principale.
  - Support distant : 80 télétravailleurs.
  - Partenaire externe : accès API uniquement.
- **État ARESlabs de départ** : deux sites simulés (`vm1-Host`, `vm2-Host`)
  sur un seul hôte Ubuntu, reliés par un tunnel GRE **non chiffré**
  (`100.64.0.0/30`) ; DMZ `192.0.2.0/27` avec `vm2` et `www` ; Cloud simulé
  `10.0.40.0/24` (`cloud-gw`, `app-cloud`) non encore raccordé ; NetBox
  en `10.0.10.60` ; plusieurs composants uniques.
- **Contraintes imposées** :
  - SLO API client : 99,9 % mensuel ;
  - accès partenaire limité à une application ;
  - journalisation obligatoire des accès admin ;
  - croissance x2 utilisateurs en 18 mois.
- **Données reçues** : plan IP partiel du profil B, topologie canonique
  ARESlabs, `source_of_truth_cible.yaml`. _Ajouter ici les données distribuées
  en séance (logs, incident tiré au sort)._
- **Hypothèses ajoutées** :
  - H1 : l'API client est servie depuis le Cloud public (production
    principale) ; les clients y accèdent par Internet, pas par le siège.
  - H2 : la DMZ API (`10.50.20.0/24`) est hébergée au datacenter privé et
    porte la passerelle API exposée au partenaire ; le back-end est dans le
    Cloud.
  - H3 : le datacenter privé n'a pas de préfixe dans le profil ; on lui
    attribue `10.50.0.0/22` (120 serveurs, x2 prévu → 240, marge incluse).
  - H4 : la croissance x2 s'applique aussi aux télétravailleurs (80 → 160).
  - H5 : le partenaire se connecte depuis une adresse publique fixe connue
    (représentée en maquette par `203.0.113.0/24`, plage de documentation).
  - H6 : le mois de référence du SLO fait 30 jours.

## 2. Décision retenue

**Décision** : architecture hybride en **zones de confiance** avec un point de
contrôle par zone :

1. sept zones (Users, Admin, Remote, DMZ API, Partenaire, DC privé, Cloud
   Prod), chacune dans sa propre VRF ;
2. un plan d'adressage **corrigé** : Users Lyon passe en `/23` et VPN Remote
   est déplacé hors de Users ;
3. l'accès partenaire passe **uniquement** par une passerelle API en DMZ
   (tcp/443, mTLS, IP source filtrée) ;
4. l'administration passe **uniquement** par un bastion avec MFA, et tous les
   accès sont journalisés de façon centralisée ;
5. le lien hybride DC ↔ Cloud et le lien intersite sont **chiffrés** (GRE
   remplacé par WireGuard/IPsec en M4).

**Alternatives rejetées** :

- **Alternative 1** : réseau plat au siège avec des ACL sur le routeur de
  bordure.
  - **Pourquoi rejetée** : l'exigence « accès partenaire limité à une
    application » et la journalisation des accès admin exigent des points de
    contrôle entre zones internes (flux est-ouest). Un réseau plat laisse un
    poste compromis joindre directement le DC et l'admin.
- **Alternative 2** : exposer l'API partenaire directement depuis le Cloud,
  sans DMZ on-premise.
  - **Pourquoi rejetée pour M1** : le profil impose une zone « DMZ API
    exposé partenaire » dans le plan IP. L'option reste **candidate en M6** :
    elle supprime la dépendance au lien hybride pour le partenaire (voir §6).
- **Alternative 3** : garder le plan IP du profil tel quel et gérer le
  chevauchement VPN/Users par du NAT.
  - **Pourquoi rejetée** : le NAT masque le conflit sans le résoudre. Il
    casse la traçabilité des accès (la journalisation admin verrait des
    adresses traduites) et complique le routage retour. Le réadressage est
    peu coûteux tant que le réseau n'est pas en production.

## 3. Justification

**Exigences concernées** :

- **Disponibilité** : 99,9 % par mois = **43,2 min** d'indisponibilité
  tolérée (30 j × 24 h × 60 min × 0,001). Toute dépendance sur le chemin de
  l'API (DNS, passerelle API, lien hybride, `app-cloud`) doit être redondée
  ou sortie de ce chemin.
- **Sécurité** : partenaire confiné à une seule application ; admin
  seulement via bastion + MFA ; aucun flux initié depuis la DMZ vers
  l'interne.
- **Performance** : le trafic client va directement au Cloud (H1). Le lien
  hybride porte seulement le trafic partenaire, le support et
  l'administration, ce qui limite la bande passante WAN nécessaire.
- **Exploitabilité** : une VRF par zone permet une politique lisible
  (une règle = un couple de zones) ; source de vérité unique dans NetBox et
  `source_of_truth_cible.yaml`.
- **Coût** : pas d'équipement dédié par zone. La segmentation est faite par
  VRF et nftables sur les routeurs Linux existants (ARESlabs). Dimensionner
  maintenant pour x2 évite un réadressage payant dans 18 mois.

**Flux concernés** (flux critiques ; matrice complète au §4) :

| Source | Destination | Service/protocole | Criticité | Contrôle attendu |
| --- | --- | --- | --- | --- |
| Clients Internet | Cloud Prod (API) | tcp/443 | **Critique (SLO 99,9 %)** | WAF/LB Cloud, mesure SLI |
| Partenaire | DMZ API (passerelle) | tcp/443 | Haute | IP source + mTLS, une seule route API |
| DMZ API | Cloud Prod (back-end API) | tcp/443 | Haute | Seul flux sortant autorisé depuis la DMZ |
| Admin (bastion) | Toutes zones | tcp/22, tcp/443 | Haute | MFA, session journalisée |
| Remote (VPN) | Cloud Prod, DC privé | tcp/443 | Moyenne | VPN authentifié, pas d'accès Admin |

## 4. Architecture proposée

**Évolution apportée à ARESlabs** : on ajoute les zones métier du profil B
sous forme de VRF, au-dessus de l'infrastructure commune, qui n'est pas
modifiée.

### Plan d'adressage corrigé

| Zone | Préfixe profil | Préfixe retenu | Taille | Justification |
| --- | --- | --- | --- | --- |
| Users Lyon | `10.40.10.0/24` | **`10.40.10.0/23`** | 510 hôtes | 250 × 2 = 500 → le /24 (254) est insuffisant |
| VPN Remote | `10.40.10.128/25` | **`10.40.12.0/24`** | 254 hôtes | Supprime le chevauchement ; 80 × 2 = 160 |
| Admin | `10.40.250.0/24` | `10.40.250.0/24` | 254 hôtes | Inchangé |
| DMZ API | `10.50.20.0/24` | `10.50.20.0/24` | 254 hôtes | Inchangé |
| DC privé | _absent_ | **`10.50.0.0/22`** | 1022 hôtes | Hypothèse H3 |
| Cloud Prod | `10.60.0.0/20` | `10.60.0.0/20` | 4094 hôtes | Inchangé |
| Partenaire | _externe_ | `203.0.113.0/24` (maquette) | -- | Hypothèse H5 |

Vérification : aucun préfixe retenu ne chevauche un autre, ni les préfixes
ARESlabs (`10.0.0.0/16`, `100.64.0.0/30`, `172.16.30.0/24`, `192.0.2.0/27`).

### Correspondance profil B ↔ objets ARESlabs

| Zone profil B | VRF | Objet ARESlabs qui la représente |
| --- | --- | --- |
| Admin | `admin` | Management `10.0.10.0/24`, `vm-mgnt` = bastion |
| Users Lyon | `users` | Site 1 (`vm1-router`), namespace `ns_users` |
| VPN Remote | `remote` | Site 1 (`vm1-router`), namespace `ns_remote` |
| DC privé | `prod` | Overlay applicatif `172.16.30.0/24` |
| DMZ API | `dmz` | DMZ `192.0.2.0/27`, `www` = passerelle API |
| Cloud Prod | `cloud` | Cloud simulé `10.0.40.0/24`, `app-cloud` = back-end API |
| Partenaire | `partner` | Namespace sur l'underlay (Internet simulé) |

### Matrice de flux (politique par défaut : **deny**)

| Src ↓ / Dst → | Admin | Users | Remote | DC privé | DMZ API | Cloud Prod | Internet |
| --- | --- | --- | --- | --- | --- | --- | --- |
| **Admin (bastion)** | -- | 22 | 22 | 22, 443 | 22, 443 | 22, 443 | 443 (MAJ) |
| **Users** | ✗ | -- | ✗ | 443 | ✗ | 443 | 80, 443 |
| **Remote** | ✗ | ✗ | -- | 443 | ✗ | 443 | ✗ (via proxy) |
| **DC privé** | ✗ | ✗ | ✗ | -- | ✗ | 443 (réplication) | ✗ |
| **DMZ API** | ✗ | ✗ | ✗ | ✗ | -- | 443 (back-end) | ✗ |
| **Partenaire** | ✗ | ✗ | ✗ | ✗ | 443 (mTLS) | ✗ | -- |
| **Clients Internet** | ✗ | ✗ | ✗ | ✗ | ✗ | 443 (API) | -- |

Les services d'infrastructure (DNS, DHCP, NTP, syslog) sont traités en M3.
Chaque zone peut joindre les résolveurs DNS et les serveurs NTP, et envoyer
ses journaux au collecteur de la zone Admin.

### Compromis structurants

| Choix | Ce qu'on gagne | Ce qu'on accepte |
| --- | --- | --- |
| DMZ API on-premise | Contrôle local du point d'exposition partenaire | Dépendance au lien hybride (risque SLO, §6) |
| VRF + nftables sur Linux | Coût nul, cohérent avec ARESlabs | Pas d'inspection applicative (WAF à ajouter en DMZ) |
| Réadressage immédiat | Pas de dette pour la croissance x2 | Documentation et DHCP à reprendre (M3) |
| Bastion unique | Traçabilité simple, un seul point à journaliser | Point unique de panne pour l'admin (à doubler en M3/M4) |

## 5. Preuves

**Preuve 1 -- Chevauchement dans le plan IP du profil**

- **Observation** : `VPN Remote 10.40.10.128/25` est inclus dans
  `Users Lyon 10.40.10.0/24` (les adresses 10.40.10.128 à .255 sont
  communes). Le profil le signale lui-même comme « chevauchement
  volontaire ».
- **Interprétation** : un routeur qui connaît les deux préfixes choisira la
  route la plus spécifique (LPM, démo
  [`01-lpm.sh`](../../../../CM/demos/routage/01-lpm.sh)). Les postes Users
  en .128 à .254 deviennent injoignables, ou le retour VPN part vers le LAN.
  Deux VRF distinctes ne suffisent pas non plus : les journaux admin ne
  permettraient plus d'identifier sans ambiguïté la source d'une session.
- **Impact architectural** : on réadresse VPN Remote en `10.40.12.0/24`. Le
  contrôle d'absence de chevauchement devient un test automatique de la
  source de vérité (M8).

**Preuve 2 -- Sous-dimensionnement de Users Lyon**

- **Observation** : le plan IP donne `10.40.10.0/24`, soit 254 adresses
  utilisables, pour 250 utilisateurs. La croissance prévue est x2 en 18 mois.
- **Interprétation** : le /24 est plein à 98 % dès le départ, sans compter
  les imprimantes, téléphones et autres équipements. Il sera épuisé avant la
  croissance.
- **Impact architectural** : on passe en `10.40.10.0/23`. Cela suppose que
  `10.40.11.0/24` reste libre, ce qui est vrai dans le plan du profil.

**Preuve 3 -- Lien intersite ARESlabs non chiffré**

- **Observation** : `00_scenario_fil_rouge.md` indique « GRE n'est pas
  chiffré » ; le tunnel `100.64.0.0/30` transporte l'overlay en clair.
- **Interprétation** : les sessions admin et les appels API partenaire
  traverseraient le WAN en clair. C'est incompatible avec la journalisation
  obligatoire des accès admin, qui suppose des accès authentifiés et
  intègres.
- **Impact architectural** : le chiffrement WireGuard/IPsec devient une
  exigence du jalon M4.

**Preuve 4 -- La source de vérité ne représente pas le profil**

- **Observation** : `source_of_truth_cible.yaml` ne définit que les VRF
  `admin`, `transport`, `prod`, `dmz`, `cloud`. Il n'y a ni `users`, ni
  `remote`, ni `partner`, et aucune règle ne limite le partenaire.
- **Interprétation** : en l'état, l'exigence « accès partenaire limité à une
  application » ne peut être ni déployée ni vérifiée automatiquement.
- **Impact architectural** : on ajoute ces VRF et les règles
  `partner-to-dmz-api-https` et `deny-partner-to-any` dans la source de
  vérité.

## 6. Scénario de panne

**Incident testé** : coupure du lien hybride entre le datacenter privé et le
Cloud Prod. En maquette : `ip link set <tunnel> down` entre `vm2-router` et
`cloud-gw`.

**Impact attendu** :

- les clients Internet → API Cloud ne sont **pas impactés** (H1 : chemin
  direct), donc le SLO client est préservé ;
- le partenaire → DMZ API → back-end Cloud est **coupé** : la passerelle
  répond 502/504 ;
- la réplication DC ↔ Cloud est suspendue.

**Comportement de l'architecture** : sans redondance, le partenaire perd
l'API pendant toute la durée de la coupure. Si la coupure dépasse 43 min et
que le partenaire est couvert par le SLO, le budget d'erreur du mois est
consommé.

**Correction minimale** :

- un second chemin hybride indépendant (tunnel IPsec par Internet en
  secours du lien principal), avec basculement automatique par routage
  (ECMP ou métriques, démo
  [`08-redondance-liens.sh`](../../../../CM/demos/routage/08-redondance-liens.sh)) ;
- à évaluer en M6 : déplacer la passerelle partenaire dans le Cloud
  (alternative 2), ce qui retire le lien hybride du chemin critique.

**Validation après correction** :

| Étape | Contenu |
| --- | --- |
| Exigence mesurable | Disponibilité de l'API partenaire ≥ 99,9 % ; basculement < 30 s |
| Panne injectée | Mise à l'état down du lien hybride principal |
| Métrique / journal | Sonde HTTP synthétique partenaire → `/health` toutes les 5 s ; route active (`ip route get 10.60.0.10`) ; journaux du tunnel |
| Critère d'acceptation | Moins de 6 sondes en échec consécutives ; la route bascule sur le tunnel de secours ; aucune alerte « partenaire down » au-delà de 30 s |

## 7. Limites

- **Limite connue 1** : la maquette tient sur un seul serveur physique. Le
  basculement prouve un comportement **logique** (routage, politique), pas
  une disponibilité physique. En production, DC, Cloud et siège sont trois
  domaines de panne distincts, avec des opérateurs différents pour les deux
  liens hybrides.
- **Limite connue 2** : le bastion unique et la DMZ API on-premise restent
  des points uniques de panne à ce stade. La journalisation admin ne vaut
  que si le collecteur de journaux est lui-même protégé et redondé (M5).
- **Évolution proposée** :
  - M2 : VRF et nftables pour appliquer la matrice de flux ;
  - M3 : DHCP pour `10.40.10.0/23` et DNS redondé ;
  - M4 : WireGuard/IPsec, bastion MFA, ZTNA pour les télétravailleurs ;
  - M5 : SLI/SLO de l'API et alertes sur le budget d'erreur ;
  - M6 : décision sur la passerelle partenaire dans le Cloud.
