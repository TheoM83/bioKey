# BioKey

## Ce que fait BioKey

BioKey transforme le téléphone en clé biométrique pour le PC. Le téléphone
signe des demandes d'authentification avec l'empreinte digitale ou Face ID.
Le PC vérifie la signature et déverrouille ou lance les applications
protégées.

## Installer

1. **Sur le PC** : lancer `BioKey-Setup-x.y.z.exe`, suivant, terminé — BioKey
   apparaît dans la barre système.
2. **Sur le téléphone** : ouvrir `BioKey-x.y.z.apk` depuis le gestionnaire de
   fichiers du téléphone (autoriser « Sources inconnues » /
   « Installer des applications inconnues » si demandé), ouvrir BioKey,
   accepter les notifications et l'exclusion de batterie.
3. **Appairer** : icône BioKey → Téléphone → Afficher le QR → scanner depuis
   le téléphone → poser le doigt.

## Protéger une application

Icône BioKey → Apps → Ajouter → « Créer le raccourci ».

## Sécurité en une phrase

Chaque appareil garde sa clé privée sur lui ; seules des signatures sont
échangées, jamais de secret.

## Construire soi-même

```powershell
tool/build_release.ps1
```

Utilisez `pwsh -File tool/build_release.ps1` si PowerShell 7 est installé, sinon `powershell -File tool/build_release.ps1`.

Prérequis : Flutter, Android SDK, Inno Setup, et le Mode développeur Windows
(Paramètres → Système → Espace développeurs) pour compiler la version
Windows.
