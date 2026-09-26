# BioKey

## Ce que fait BioKey

BioKey transforme le téléphone en clé biométrique pour le PC. Le téléphone
signe des demandes d'authentification avec l'empreinte digitale ou Face ID.
Le PC vérifie la signature et déverrouille ou lance les applications
protégées.

## Installer

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

## Protéger une application

Icône BioKey → Ouvrir BioKey… → onglet Apps → Ajouter → « Créer le raccourci ».

## Sécurité en une phrase

Chaque appareil garde sa clé privée sur lui et les demandes sont approuvées
par signature ; le seul secret échangé est un secret de session, transmis
une seule fois à l'appairage, dans la connexion TLS épinglée par le QR.

## Construire soi-même

```powershell
tool/build_release.ps1
```

Utilisez `pwsh -File tool/build_release.ps1` si PowerShell 7 est installé, sinon `powershell -File tool/build_release.ps1`.

Prérequis : Flutter, Android SDK, Inno Setup, et le Mode développeur Windows
(Paramètres → Système → Espace développeurs) pour compiler la version
Windows.

L'APK « release » produit est signé avec la clé de **débogage** de la
machine qui l'a compilé : il s'installe, mais une mise à jour compilée sur
une autre machine sera refusée (signature différente — il faudrait
désinstaller, donc réappairer). Pour distribuer des mises à jour, créez un
keystore (`keytool -genkey …`) et configurez `signingConfigs.release` dans
`android/app/build.gradle.kts`.
