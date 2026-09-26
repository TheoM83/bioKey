# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-09-26

J1 MVP: Android phone role + Windows PC role, usable end to end on a LAN.

### Added

- QR pairing between phone and PC, with certificate-pinned `wss://`.
- Biometric approval of authentication requests (fingerprint), signature
  never leaves the phone.
- Protected applications: add, create a launcher shortcut, open by
  fingerprint from the PC.
- Windows system tray integration (menu, window, notifications).
- Windows installer (`BioKey-Setup-x.y.z.exe`, Inno Setup).
- Android foreground service so requests are received screen-locked.
- Session secret issued once at pairing, used to authenticate
  reconnections without re-prompting for biometrics every time.
