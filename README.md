# BioKey

Le téléphone comme clé biométrique du PC · Your phone's fingerprint as your PC's biometric key.

[![CI](https://github.com/TheoM83/bioKey/actions/workflows/ci.yml/badge.svg)](https://github.com/TheoM83/bioKey/actions/workflows/ci.yml)
![Flutter](https://img.shields.io/badge/Flutter-3.35-02569B?logo=flutter&logoColor=white)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Platforms](https://img.shields.io/badge/platform-Android%20%C2%B7%20Windows-lightgrey)

---

## Français

### Ce que fait BioKey

BioKey transforme le téléphone en clé biométrique pour le PC. Le téléphone
signe des demandes d'authentification avec l'empreinte digitale. Le PC
vérifie la signature et lance les applications protégées. Pas de serveur,
pas de cloud, pas de compte : tout se passe sur le réseau local.

```
 ┌──────────────┐   wss://  TLS épinglé (QR)   ┌──────────────┐
 │  Téléphone   │ ───────────────────────────► │      PC      │
 │  (Android)   │        signature seule        │  (Windows)   │
 │  clé biométr.│ ◄─────────────────────────── │  vérif. + tray│
 └──────────────┘        même LAN               └──────────────┘
```

### Installer

1. **Sur le PC** : lancer `BioKey-Setup-x.y.z.exe`, suivant, terminé — BioKey
   apparaît dans la barre système. Au premier lancement, le pare-feu Windows
   Defender demande d'autoriser BioKey : cochez **Réseaux privés** et
   vérifiez que votre Wi-Fi est bien déclaré en réseau **privé**
   (Paramètres → Réseau et Internet → Wi-Fi → propriétés du réseau), sinon
   le téléphone ne pourra pas joindre le PC.
2. **Sur le téléphone** : ouvrir `BioKey-x.y.z.apk` depuis le gestionnaire de
   fichiers du téléphone (autoriser « Sources inconnues » /
   « Installer des applications inconnues » si demandé), ouvrir BioKey,
   accepter les notifications et l'exclusion de batterie.
3. **Appairer** : icône BioKey → Ouvrir BioKey… → onglet Téléphone →
   Afficher le QR → scanner depuis le téléphone → poser le doigt.

### Hors de chez soi

Pour joindre le PC hors du réseau local, installez
[WireGuard](https://www.wireguard.com/) ou [Tailscale](https://tailscale.com/)
sur le téléphone et sur le PC, dans le même tunnel privé. Sur le téléphone,
ouvrez BioKey → menu du PC (⋮) → « Modifier l'adresse… » → entrez l'IP du
tunnel ou le nom MagicDNS du PC (ex. `pc-maison.tailnet.ts.net`). L'appairage,
le certificat épinglé et le secret de session restent inchangés — seule
l'adresse change. BioKey n'utilise et ne fournit aucun relais : le trafic
passe uniquement par votre tunnel.

### Protéger une application

Icône BioKey → Ouvrir BioKey… → onglet Apps → Ajouter → « Créer le
raccourci ».

### Sécurité en une phrase

L'empreinte ne quitte jamais le téléphone ; seule une signature ECDSA
voyage ; la connexion est en TLS brut dont le PC épingle le certificat via
le QR — aucune bibliothèque réseau tierce : `dart:io` (TLS) + `pointycastle`
seuls ; la reconnexion utilise un secret de session remis une seule fois à
l'appairage. Détails et modèle de menace : [SECURITY.md](SECURITY.md).

### Construire soi-même

Prérequis : Flutter 3.35, Android SDK 35, Java 17, [Inno Setup](https://jrsoftware.org/isinfo.php),
et le Mode développeur Windows (Paramètres → Système → Espace développeurs)
pour compiler la version Windows.

```powershell
pwsh -File tool/build_release.ps1
```

Options : `-SkipWindows` ou `-SkipAndroid` pour ne construire qu'une moitié.
Utilisez `powershell -File tool/build_release.ps1` si PowerShell 7 (`pwsh`)
n'est pas installé.

L'APK « release » produit est signé avec la clé de **débogage** de la
machine qui l'a compilé (pas encore de keystore de release) : il s'installe,
mais une mise à jour compilée sur une autre machine sera refusée (signature
différente — il faudrait désinstaller, donc réappairer).

### Feuille de route

- **J1 — MVP (fait)** : appairage QR, approbation biométrique, apps
  protégées, barre système, installeur, service premier plan, TLS épinglé
  + secret de session.
- **J2 — Confort** : historique des demandes, raccourci clavier global,
  i18n anglais.
- **J3 — Multi-OS** : macOS, Linux, iOS, repli Bluetooth LE.

Détails : [CAHIER_DES_CHARGES.md](CAHIER_DES_CHARGES.md) (spécification,
FR) et [docs/superpowers/plans/](docs/superpowers/plans/) (plan
d'implémentation).

### Contribuer

```
flutter analyze && flutter test
```

Commits au format [Conventional Commits](https://www.conventionalcommits.org/).
Pour un changement de protocole (`lib/core/`), ouvrez une issue avant la PR.

### Licence

[MIT](LICENSE)

---

## English

### What it does

BioKey turns the phone into a biometric key for the PC. The phone signs
authentication requests with a fingerprint. The PC verifies the signature
and launches the protected app. No server, no cloud, no account — everything
stays on the local network.

```
 ┌──────────────┐   wss://  pinned TLS (QR)    ┌──────────────┐
 │    Phone     │ ───────────────────────────► │      PC      │
 │  (Android)   │        signature only         │  (Windows)   │
 │ biometric key│ ◄─────────────────────────── │ verify + tray │
 └──────────────┘        same LAN               └──────────────┘
```

### Install

1. **On the PC**: run `BioKey-Setup-x.y.z.exe`, Next, Finish — BioKey
   appears in the system tray. On first launch Windows Defender Firewall
   will ask to allow BioKey: check **Private networks**, and make sure your
   Wi-Fi is set to a **private** network (Settings → Network & Internet →
   Wi-Fi → network properties), otherwise the phone won't be able to reach
   the PC.
2. **On the phone**: open `BioKey-x.y.z.apk` from the phone's file manager
   (allow "Install unknown apps" if prompted), open BioKey, accept
   notifications and the battery-optimization exclusion.
3. **Pair**: BioKey tray icon → Open BioKey… → Phone tab → Show QR → scan
   from the phone → place your finger.

### Away from home

To reach the PC outside the local network, install
[WireGuard](https://www.wireguard.com/) or [Tailscale](https://tailscale.com/)
on both the phone and the PC, joined to the same private tunnel. On the
phone, open BioKey → the PC's menu (⋮) → "Modifier l'adresse…" → enter the
PC's tunnel IP or MagicDNS name (e.g. `pc-maison.tailnet.ts.net`). Pairing,
the pinned certificate and the session secret are unchanged — only the
address changes. BioKey never uses or provides a relay: traffic only ever
flows through your own tunnel.

### Protect an app

Tray icon → Open BioKey… → Apps tab → Add → "Create shortcut".

### Security in one sentence

The fingerprint never leaves the phone; only an ECDSA signature travels;
the connection is raw pinned TLS with the PC's certificate pinned via the
QR code — no third-party network library: `dart:io` (TLS) + `pointycastle`
alone; reconnection uses a session secret issued once at pairing time.
Details and threat model: [SECURITY.md](SECURITY.md).

### Build it yourself

Prerequisites: Flutter 3.35, Android SDK 35, Java 17,
[Inno Setup](https://jrsoftware.org/isinfo.php), and Windows Developer Mode
(Settings → System → For developers) to build the Windows target.

```powershell
pwsh -File tool/build_release.ps1
```

Flags: `-SkipWindows` or `-SkipAndroid` to build only one half. Use
`powershell -File tool/build_release.ps1` if PowerShell 7 (`pwsh`) isn't
installed.

The produced release APK is signed with the **debug** key of the build
machine (no release keystore yet): it installs fine, but an update built on
another machine will be rejected (different signature — you'd need to
uninstall and re-pair).

### Roadmap

- **J1 — MVP (done)**: QR pairing, biometric approval, protected apps,
  system tray, installer, foreground service, pinned TLS + session secret.
- **J2 — Polish**: request history, global hotkey, English i18n.
- **J3 — Multi-OS**: macOS, Linux, iOS, Bluetooth LE fallback.

More: [CAHIER_DES_CHARGES.md](CAHIER_DES_CHARGES.md) (spec, French) and
[docs/superpowers/plans/](docs/superpowers/plans/) (implementation plan).

### Contributing

```
flutter analyze && flutter test
```

Use [Conventional Commits](https://www.conventionalcommits.org/). For a
protocol change (`lib/core/`), open an issue before sending a PR.

### License

[MIT](LICENSE)
