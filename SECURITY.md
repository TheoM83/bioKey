# Security Policy

## Supported versions

Only the `1.x` line receives security fixes. BioKey has no auto-update
mechanism yet; please rebuild or reinstall from the latest release.

## Reporting a vulnerability

- Preferred: use [GitHub private vulnerability reporting](https://github.com/TheoM83/bioKey/security/advisories/new)
  for anything sensitive (key handling, signature verification, pairing,
  TLS pinning).
- Non-sensitive issues (typos in prompts, minor UX bugs with no security
  impact) can be filed as a normal [GitHub issue](https://github.com/TheoM83/bioKey/issues).

Please do not open a public issue for a vulnerability that could be
exploited before a fix ships.

## Threat model (summary)

Full detail: `CAHIER_DES_CHARGES.md` §7.1 (French).

BioKey protects against:

- **Replay** of a signed response — random 32-byte nonce, unique request
  id, 30s expiry, single-use pending list.
- **PC spoofing / LAN MITM** — TLS 1.3; the phone pins the certificate
  fingerprint it read from the QR code (an out-of-band, visual channel).
- **Phone spoofing** — the PC only accepts signatures verifiable with the
  public key recorded at pairing; reconnection additionally requires the
  session secret issued once at pairing.
- **Forced pairing by a third party on the LAN** — single-use pairing
  token, 120s expiry, biometric confirmation required to finalize.
- **Private key extraction** — key lives in Android Keystore
  (StrongBox/TEE), non-exportable, invalidated on biometric enrollment
  change.

Explicitly **out of scope**: a hostile actor with **local administrator
access on the PC**. BioKey protects against casual use of an unlocked
machine, not against a compromised or admin-controlled host. There is no
server, relay, cloud account, or telemetry — everything stays on the LAN.
