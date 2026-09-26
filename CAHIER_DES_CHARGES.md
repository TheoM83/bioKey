# Opsidious BioKey — Cahier des charges

> Version 0.2 — 2026-09-26 — Statut : à valider
> Projet : Opsidious · Remplace la v0.1 (Kotlin + .NET, Android/Windows uniquement)

## 1. Résumé

**BioKey** transforme le capteur d'empreintes du téléphone en **clé biométrique externe** pour l'ordinateur. L'utilisateur lance une action protégée sur le PC ; le téléphone vibre, affiche « Ouvrir *Mon app* sur *PC-MAISON* ? », l'utilisateur pose son doigt, le PC reçoit une signature et exécute l'action.

Trois principes non négociables :

1. **L'empreinte ne quitte jamais le téléphone.** Seule une signature ECDSA voyage.
2. **Aucun serveur.** Ni cloud, ni relais, ni compte. Le téléphone parle directement au PC sur le réseau local (le PC écoute lui-même sur un port TLS). Rien ne sort du LAN.
3. **Un seul code source.** Une application Flutter, deux rôles (« Téléphone » et « Ordinateur »), compilée pour Android, iOS, Windows, macOS et Linux.

| Rôle | Appareil | Fait quoi |
|---|---|---|
| **Téléphone** | Android (v1), iOS (v2) | Détient la clé privée liée à l'empreinte, affiche la demande, signe |
| **Ordinateur** | Windows (v1), macOS / Linux (v1.1) | Icône de barre système, appairage QR, liste d'apps protégées, vérifie la signature, lance l'app |

## 2. Décisions (ferment les questions ouvertes de la v0.1)

| # | Question | Décision | Pourquoi |
|---|---|---|---|
| D1 | Nom | **Opsidious BioKey** (dépôt `bioKey`) | Clair, déjà utilisé |
| D2 | Verrou d'apps « à la volée » (F-22 v0.1) | **Abandonné.** BioKey protège **ses propres raccourcis** uniquement | La suspension de processus est contournable par tout admin local ; complexité énorme pour une fausse sécurité |
| D3 | PIN / schéma de repli sur le téléphone | **Non.** Biométrie forte uniquement (`BIOMETRIC_STRONG` / Face ID / Touch ID) | Un repli PIN abaisse la sécurité au niveau du PIN. Si la biométrie casse, on réappaire en 30 s |
| D4 | Déverrouillage de session Windows (Credential Provider) | **Hors périmètre, sans date.** | Pilote natif C++, hors Flutter, risque de se bloquer hors de sa session. Peut-être jamais |
| D5 | Réseau | **v1 = même LAN.** Bluetooth LE en repli plus tard (J3) | Pas de serveur ⇒ pas de push hors LAN, assumé |
| D6 | Framework | **Flutter, mono-dépôt, deux rôles** (voir §8 pour les alternatives) | Multi-OS quasi gratuit, un seul langage, un seul protocole testé une fois |
| D7 | Code de vérification anti-MITM (F-05 v0.1) | **Supprimé.** | Le QR affiché par le PC transporte déjà l'empreinte de son certificat : le canal est authentifié par la caméra. Le code court est redondant |
| D8 | Plusieurs PC par téléphone | **Oui dès la v1.** Une seule clé biométrique par téléphone, sa clé publique est donnée à chaque PC appairé | Coût nul : c'est une liste. Une clé par PC n'apporte rien : la clé est déjà liée à la biométrie, et le plugin ne gère qu'une clé |
| D9 | Plusieurs téléphones par PC | **Plus tard** | Rare en usage perso |

## 3. Objectifs et périmètre

### Objectifs

1. Ouvrir une app protégée en **un geste d'empreinte**, < 3 s de bout en bout sur LAN.
2. Appairage en **< 1 min**, un scan de QR, zéro saisie.
3. **Zéro configuration** après l'appairage. Une seule fenêtre côté PC, un seul écran utile côté téléphone.
4. Sécurité « clé matérielle » : clé privée non exportable (StrongBox / TEE / Secure Enclave), signature possible **uniquement** après biométrie.
5. **Même code partout.** Ajouter un OS = ajouter une cible de compilation, pas une app.

### Hors périmètre (v1)

- Serveur, relais, cloud, compte, télémétrie — **définitivement**.
- Émulation d'un lecteur Windows Hello / pilote WBF (impossible sans certification Microsoft).
- Credential Provider / déverrouillage de session OS (D4).
- Interception des lancements d'apps hors BioKey (D2).
- Coffre de secrets (reporté J3).

## 4. Utilisateur cible

Une personne (l'auteur) : Nothing Phone (Android 15 / Nothing OS), PC Windows 11, LAN domestique. Niveau technique élevé, exigence « ça marche tout seul ». Ouverture possible à des proches ⇒ installation sans ligne de commande.

## 5. Exigences fonctionnelles

MoSCoW : **M** indispensable v1 · **S** souhaitable · **C** plus tard.

### 5.1 Appairage

| ID | Exigence | Prio |
|---|---|---|
| F-01 | Le PC affiche un **QR code** contenant : version, identifiant PC, nom, hôte:port, empreinte SHA-256 du certificat TLS, jeton à usage unique (16 octets), expiration 120 s | M |
| F-02 | Le téléphone scanne, vérifie l'empreinte du certificat à la connexion, génère une paire de clés **liée à la biométrie**, envoie la clé publique + jeton | M |
| F-03 | Le PC renvoie un défi ; le téléphone le signe **après empreinte** ; le PC vérifie puis mémorise la clé publique. Les deux écrans affichent « Appairé » | M |
| F-04 | Révocation depuis le PC **et** depuis le téléphone (supprime la clé du Keystore) | M |
| F-05 | Un téléphone peut être appairé à plusieurs PC (même clé, liste de PC) | M |

### 5.2 Demande d'authentification

| ID | Exigence | Prio |
|---|---|---|
| F-10 | Le PC envoie une demande signable (id, action, libellé, nonce 32 octets, émission, expiration ≤ 30 s) | M |
| F-11 | Le téléphone la reçoit **écran verrouillé compris** et affiche l'invite biométrique système avec le contexte exact (« Ouvrir *Mon app* sur *PC-MAISON* ? ») | M |
| F-12 | Succès biométrique ⇒ signature des octets exacts de la demande ⇒ retour au PC ⇒ vérification signature + id en attente + expiration ⇒ exécution | M |
| F-13 | Refus, expiration, échec biométrique, téléphone hors ligne ⇒ **rien n'est exécuté**, le PC affiche la raison | M |
| F-14 | Une demande ne peut être validée qu'**une fois** (id retiré de la liste d'attente dès la première réponse) | M |
| F-15 | Le téléphone peut initier (« Déverrouiller mon PC » ⇒ ouvre le sélecteur d'apps sur le PC) | C |

### 5.3 Actions protégées côté PC

| ID | Exigence | Prio |
|---|---|---|
| F-20 | Liste d'**apps protégées** : exécutable, raccourci, app Store, URL/protocole. Ajout par glisser-déposer ou sélecteur de fichier | M |
| F-21 | Pour chaque app, BioKey crée un **raccourci protégé** (`.lnk` / `.desktop` / alias) qui appelle `biokey open <id>`. Si BioKey tourne déjà, l'instance unique reçoit la commande | M |
| F-22 | Menu de la barre système : liste des apps protégées, un clic = demande d'empreinte | M |
| F-23 | Raccourci clavier global ⇒ sélecteur d'apps | S |
| F-24 | « Rester déverrouillée N min » par app (défaut 0 = à chaque fois) | S |
| F-25 | Historique des 100 dernières demandes (date, app, résultat) | S |
| F-26 | Coffre local de secrets déverrouillé par BioKey | C |

### 5.4 Intégration système

| ID | Exigence | Prio |
|---|---|---|
| F-30 | PC : lancement à l'ouverture de session, icône barre système, notifications natives, thème clair/sombre système, fenêtre fermée = réduite dans la barre | M |
| F-31 | Téléphone : service premier plan léger (Android), notification haute priorité ouvrant directement l'invite biométrique, guide d'exclusion de l'optimisation batterie au premier lancement | M |
| F-32 | Découverte du PC par **mDNS** (`_biokey._tcp`), reconnexion automatique après veille / changement de Wi-Fi / redémarrage | M |
| F-33 | Tuile de réglages rapides Android, raccourci d'app | C |
| F-34 | Repli **Bluetooth LE** quand pas de LAN commun | C |

## 6. Exigences non fonctionnelles

| Domaine | Exigence |
|---|---|
| Latence | Clic PC → invite affichée sur le téléphone < 1 s (LAN) ; scénario complet < 3 s |
| Fiabilité | Reconnexion sans intervention ; 0 demande fantôme ; 0 rejeu possible |
| Batterie | Connexion WebSocket persistante idle + ping toutes les 45 s ; pas de polling ; < 1 % / jour au repos |
| Ressources PC | < 150 Mo RAM au repos (Flutter Windows ≈ 80–120 Mo), < 1 % CPU |
| Confidentialité | Aucune donnée ne quitte le LAN. Aucun réseau sortant (vérifiable au pare-feu) |
| Accessibilité | Tailles de texte système, contraste AA, lecteur d'écran sur les 4 écrans |
| Langues | Français, anglais (fichiers ARB, 2 fichiers) |
| Compatibilité | Android 10+ (cible 15) · Windows 10 22H2+ (cible 11) · macOS 13+ · Linux (GTK) · iOS 15+ |
| Installation | Windows : MSIX signé ou exe portable · Android : APK · macOS : `.dmg` · Linux : AppImage · iOS : TestFlight/sideload |

## 7. Sécurité

### 7.1 Modèle de menace

| Menace | Contre-mesure |
|---|---|
| Rejeu d'une réponse | Nonce 32 octets aléatoire + id unique + expiration 30 s + liste d'attente à usage unique (F-14) |
| Usurpation du PC / MITM sur le LAN | TLS 1.3 ; le téléphone **épingle** l'empreinte du certificat reçue par QR (canal visuel, hors réseau) ; toute autre empreinte ⇒ connexion refusée |
| Usurpation du téléphone | Le PC n'accepte que les signatures vérifiables avec la clé publique mémorisée à l'appairage. La reconnexion (`hello`) exige en plus le **secret de session** remis à l'appairage (la clé publique n'est pas un secret) ; pas de signature à la reconnexion pour ne pas demander l'empreinte à chaque fois |
| Appairage forcé par un tiers sur le LAN | Jeton à usage unique dans le QR, 120 s, + empreinte obligatoire pour finaliser |
| Vol du téléphone déverrouillé | La clé exige la biométrie **à chaque signature** ; pas de repli PIN (D3) |
| Ajout d'une empreinte par un tiers | Clé invalidée à tout changement d'enrôlement biométrique ⇒ réappairage |
| Extraction de la clé privée | Keystore StrongBox (sinon TEE) / Secure Enclave, non exportable |
| Compromission des données PC | Clés publiques + liste d'apps dans le stockage sécurisé OS (DPAPI / Keychain / libsecret). Aucun secret biométrique côté PC |
| Fausse invite (phishing d'approbation) | L'invite système affiche **toujours** le libellé de l'app et le nom du PC ; timeout = refus |
| Attaquant admin local sur le PC | **Hors modèle.** BioKey protège contre l'usage occasionnel d'un PC déverrouillé, pas contre un admin hostile |

### 7.2 Cryptographie

- **Clé téléphone** : ECDSA P-256, une seule par téléphone (D8). Android : `setUserAuthenticationRequired(true)`, `BIOMETRIC_STRONG`, `setInvalidatedByBiometricEnrollment(true)`, StrongBox si dispo. iOS : Secure Enclave, `biometryCurrentSet`.
- **Identité PC** : certificat TLS auto-signé P-256 généré au premier lancement, identifiant PC = 8 premiers octets hex de SHA-256(certificat).
- **Ce qui est signé** : SHA-256 des **octets exacts** du message `auth` tel qu'envoyé par le PC. Pas de canonicalisation JSON : le téléphone signe ce qu'il a reçu, le PC vérifie sur ce qu'il a envoyé.
- **Vérification côté PC** : ECDSA P-256 / SHA-256 en Dart pur. Aucune dépendance native.

### 7.3 Protocole (JSON sur WebSocket, `wss://`, version 1)

**Appairage**

```
PC        affiche QR  biokey://pair?v=1&id=<pcId>&n=<nom>&h=<hôte>&p=<port>&fp=<sha256 cert b64url>&t=<jeton b64url>
Téléphone → PC        {"type":"pair","v":1,"token":"…","name":"Nothing Phone","pub":"<SPKI b64>"}
PC        → Téléphone {"type":"pair_challenge","nonce":"<32 o b64>"}
Téléphone → PC        {"type":"pair_proof","sig":"<ECDSA b64>"}          (après empreinte)
PC        → Téléphone {"type":"paired","pcId":"…","name":"PC-MAISON","session":"<32 o b64url>"}   (secret de session, stocké des deux côtés)
```

**Session**

```
Téléphone → PC        {"type":"hello","v":1,"pcId":"…","pub":"<SPKI b64>","session":"…"}   (à chaque connexion ; session ≠ ⇒ unknown)
PC        → Téléphone {"type":"welcome"}  ou  {"type":"unknown"}              (unknown ⇒ réappairer)
PC        → Téléphone {"type":"auth","id":"<uuid>","pcId":"…","action":"open","label":"Mon app","nonce":"…","iat":1780000000,"exp":1780000030}
Téléphone → PC        {"type":"auth_ok","id":"…","sig":"…"}
              ou      {"type":"auth_denied","id":"…","reason":"user|timeout|biometric_failed"}
Les deux              {"type":"ping"} / {"type":"pong"}  toutes les 45 s
```

Règles : tout message inconnu ou malformé ferme la connexion. Toute signature invalide = refus + entrée d'historique. Version incompatible ⇒ message d'erreur clair, pas de dégradation silencieuse.

## 8. Architecture et technologies

```
┌──────────────────────────┐   wss:// TLS 1.3, cert épinglé   ┌──────────────────────────┐
│  BioKey · rôle Téléphone │ ◄──────── WebSocket LAN ────────► │  BioKey · rôle Ordinateur│
│  Android / iOS           │                                    │  Windows / macOS / Linux │
│                          │   auth(id, nonce, label)           │                          │
│  • Clé P-256 biométrique │ ◄───────────────────────────────── │  • Serveur wss + mDNS    │
│  • Invite biométrique OS │   auth_ok(sig)                     │  • Vérif. ECDSA          │
│  • Service + notif       │ ─────────────────────────────────► │  • Barre système         │
│  • Scanner QR + mDNS     │                                    │  • Lanceur d'apps        │
└──────────────────────────┘                                    └──────────────────────────┘
        même code Dart : protocole, modèles, stockage, i18n, thème
```

### 8.1 Choix du framework — alternatives évaluées

| Option | Multi-OS | Codebases | Look natif | Biométrie liée à la clé | Verdict |
|---|---|---|---|---|---|
| **Flutter mono-dépôt** | Android, iOS, Win, mac, Linux | **1** | Material 3 partout, barre système native | `biometric_signature` (Keystore/StrongBox, Secure Enclave) | **Retenu** |
| Kotlin Multiplatform + Compose | Android natif, desktop JVM, iOS partiel | 1 (+ glue Swift) | Bon Android, desktop JVM lourd (≥ 200 Mo), barre système fragile | À écrire soi-même par OS | Non |
| Natif ×2 (Kotlin + .NET, v0.1) | Android + Windows seulement | 2 | Le meilleur | API officielles | Non : chaque OS = une app de plus |

Compromis accepté : côté PC, l'UI n'est pas Fluent mais Material 3 aux couleurs système. La fenêtre s'ouvre rarement (appairage, ajout d'app) ; ce qui compte au quotidien — barre système, notifications, raccourcis — est natif.

### 8.2 Stack retenue

| Besoin | Choix | Plateformes |
|---|---|---|
| Langage / UI | Dart 3, Flutter stable, Material 3 | toutes |
| État | Riverpod (un notifier par rôle) | toutes |
| Clé biométrique + signature | `biometric_signature` | Android, iOS (macOS/Windows aussi, inutile ici) |
| Invite biométrique | fournie par le même plugin (BiometricPrompt / LocalAuthentication) | Android, iOS |
| Scan QR | `mobile_scanner` | Android, iOS |
| Affichage QR | `qr_flutter` | desktop |
| mDNS (annonce + découverte) | `bonsoir` | toutes |
| Transport | `dart:io` `HttpServer` + `SecurityContext` + `WebSocketTransformer` (PC), `WebSocket.connect` (téléphone) — **zéro dépendance** | toutes |
| Certificat auto-signé | `basic_utils` (X509) ou `pointycastle` | desktop |
| Vérification ECDSA | `pointycastle` (Dart pur) | desktop |
| Stockage sécurisé | `flutter_secure_storage` (DPAPI / Keychain / libsecret / Keystore) | toutes |
| Service premier plan | `flutter_foreground_task` | Android |
| Notifications | `flutter_local_notifications` (mobile), `local_notifier` (desktop) | toutes |
| Barre système / fenêtre | `tray_manager`, `window_manager` | Win, mac, Linux |
| Raccourci global | `hotkey_manager` | Win, mac, Linux |
| Démarrage automatique | `launch_at_startup` | Win, mac, Linux |
| Instance unique + `biokey open <id>` | port local `127.0.0.1` fixe + jeton dans le stockage sécurisé, ou `windows_single_instance` | desktop |
| Lancement d'app | `Process.start` (Win/Linux), `open -a` (mac), `ShellExecute` via `url_launcher` pour Store/URL | desktop |
| i18n | `flutter_localizations` + ARB | toutes |
| Tests | `flutter_test` (protocole, vérif. signature, machine d'états) + test d'intégration LAN | — |

### 8.3 Organisation du code

```
biokey/
  lib/
    core/        protocole (messages, versions), crypto (vérif ECDSA, cert), stockage, i18n, thème
    phone/       rôle Téléphone : appairage, service, invite, écran État
    desktop/     rôle Ordinateur : serveur wss, mDNS, barre système, apps protégées, fenêtre
    main.dart    choisit le rôle selon la plateforme (mobile ⇒ Téléphone, desktop ⇒ Ordinateur)
  test/          core/ testé sans appareil ; desktop/ avec un faux téléphone en mémoire
```

Règle : `core/` ne dépend d'aucun plugin de plateforme. Tout ce qui touche à un OS vit derrière une interface (`BiometricSigner`, `SystemTray`, `AppLauncher`) avec une implémentation factice pour les tests.

## 9. Expérience utilisateur

### Principe : invisible tant qu'on n'en a pas besoin

**Ordinateur** — une icône de barre système. Menu : apps protégées, « Ajouter une app… », « Téléphone », « Quitter ». Une seule fenêtre, deux onglets :
- *Téléphone* : QR d'appairage (ou « Nothing Phone · connecté » + bouton Révoquer).
- *Apps* : liste, glisser-déposer, pour chaque app : « Créer le raccourci », « Rester déverrouillée N min », supprimer.

**Téléphone** — deux écrans :
- *Ordinateurs* : liste des PC appairés avec état (connecté / hors ligne), bouton « Scanner un QR », révocation par balayage.
- L'invite biométrique **système** fait tout le reste. Pas d'écran maison pour valider.

**Style** — Material 3, `ColorScheme` dynamique système, sobre. Accent rouge Nothing et titres Ndot côté téléphone seulement si la police est disponible ; sinon police système, sans regret.

### Scénario nominal

1. Double-clic sur le raccourci protégé « Mon app » (ou clic dans le menu de la barre système).
2. Le téléphone vibre, invite système : « Ouvrir *Mon app* sur *PC-MAISON* ? ».
3. Doigt posé → « Mon app » s'ouvre. Notification PC discrète « Ouvert avec BioKey ». Total < 3 s.

### Scénarios d'erreur (ce que voit l'utilisateur)

| Situation | PC | Téléphone |
|---|---|---|
| Téléphone hors ligne | Notification « Téléphone introuvable — même Wi-Fi ? » | — |
| Refus / 30 s sans réponse | Notification « Demande refusée / expirée » | Invite fermée |
| Empreintes modifiées | « Appairage invalide — scannez à nouveau le QR » | « Clé invalidée, réappairage nécessaire » |
| Signature invalide | Notification + ligne d'historique rouge | — |

## 10. Feuille de route

| Jalon | Contenu | Livrable / critère |
|---|---|---|
| **J0 — Spike (1–2 jours)** | Sur le Nothing Phone : générer la clé avec `biometric_signature`, signer un nonce. Sur Windows : vérifier en Dart pur. Vérifier l'invalidation à l'ajout d'une empreinte | **Go / no-go** sur le plugin. Si no-go : plugin maison (~200 lignes Kotlin, `BiometricPrompt.CryptoObject`) |
| **J1 — MVP Android + Windows** | F-01→05, F-10→14, F-20→22, F-30→32, protocole complet, tests `core/` | Utilisable au quotidien |
| **J2 — Confort** | F-23, F-24, F-25, guide batterie soigné, historique, i18n EN, installeur MSIX | Expérience fluide |
| **J3 — Multi-OS** | Cibles macOS + Linux (rôle Ordinateur), iOS (rôle Téléphone), BLE (F-34), F-15, F-33 | Même code, 5 OS |
| **Plus tard, sans engagement** | Coffre de secrets (F-26), plusieurs téléphones par PC | — |

## 11. Risques

| Risque | Impact | Parade |
|---|---|---|
| `biometric_signature` ne fait pas l'invalidation à l'enrôlement ou casse sur Nothing OS | Sécurité affaiblie / blocage | Testé au J0. Repli : plugin Kotlin maison, périmètre minuscule |
| Nothing OS tue le service premier plan | Demandes perdues | Exclusion batterie guidée, notification persistante, test réel ; repli : ping plus court |
| Changement d'IP / réseau | Reconnexion lente | mDNS + cache de la dernière IP + tentative immédiate au retour Wi-Fi |
| Flutter desktop : barre système sous Linux (Wayland) | Icône absente | `tray_manager` (StatusNotifier) ; documenter la limite |
| Instance unique Windows depuis un `.lnk` | Deux BioKey ouverts | Port local + jeton, testé au J1 |
| Poids Flutter Windows (~100 Mo RAM) | Ressenti « lourd » | Accepté et documenté ; fenêtre jamais rendue tant que non ouverte |

## 12. Critères d'acceptation v1

- [ ] Appairage complet en < 1 min, zéro saisie manuelle.
- [ ] App protégée ouverte par empreinte en < 3 s sur LAN.
- [ ] Refus, expiration ou hors ligne ⇒ l'app **n'est pas** lancée, raison affichée.
- [ ] Une réponse rejouée (même id, même signature) est rejetée.
- [ ] Certificat PC différent de celui du QR ⇒ le téléphone refuse la connexion.
- [ ] Ajout d'une empreinte sur le téléphone ⇒ l'appairage est rejeté, réappairage proposé.
- [ ] Veille, changement de Wi-Fi, redémarrage PC ou téléphone ⇒ reconnexion sans intervention.
- [ ] Le pare-feu ne voit **aucune** connexion sortante de BioKey hors LAN.
- [ ] Aucune donnée biométrique ni clé privée hors Keystore / Secure Enclave (revue de code + audit du stockage).
- [ ] `core/` couvert par des tests sans appareil ; le protocole passe avec un faux téléphone.

## 13. Glossaire

| Terme | Sens |
|---|---|
| Rôle | Comportement de l'app selon l'appareil : Téléphone (signe) ou Ordinateur (vérifie) |
| Épinglage | Le téléphone n'accepte que le certificat dont l'empreinte a été lue dans le QR |
| Clé liée à la biométrie | Clé privée matérielle utilisable seulement après une empreinte validée par l'OS |
| StrongBox / TEE / Secure Enclave | Puces sécurisées Android / iOS où vit la clé privée |
