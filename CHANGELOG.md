# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.1.0] - 2026-09-26

J1.1 lean transport: drops the WebSocket/mDNS libraries in favour of raw
pinned TLS and hand-rolled UDP discovery, and lets a phone reach a PC
through the user's own tunnel when they're not on the same LAN.

### Added

- UDP broadcast discovery (`dart:io`, port 47623) so the phone finds a PC
  again after it changes IP, without mDNS.
- Manual host per paired PC, for use over the user's own WireGuard/Tailscale
  tunnel when off the home LAN — BioKey itself never runs a server.
- Stricter SPKI/DER validation on the certificate/public-key material
  exchanged during pairing.
- Per-source rate limit on discovery replies (in addition to the existing
  global one), so one flooding sender can't starve replies to everyone
  else on the LAN.

### Changed

- Transport: raw pinned TLS with length-prefixed frames replaces
  WebSocket/`wss://`.
- Crypto: `pointycastle` alone covers certificate generation and ECDSA
  verification — no more `basic_utils`.
- Liveness/idle timers (phone and desktop) now run on a monotonic clock
  instead of wall-clock time, so a clock jump can't spuriously close (or
  fail to close) a link.

### Removed

- `bonsoir` (mDNS) and `basic_utils`.

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
