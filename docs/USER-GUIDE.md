# SyncPilot user guide

**English** · [简体中文](USER-GUIDE.zh-CN.md)

Manage the official Resilio Sync daemon from a Linux desktop window.

## Availability

Free Linux maintenance project under AGPL-3.0. Resilio’s separate licence and service limits still apply; no SyncPilot paid tier.

## Platforms and installation

Linux only. The official rslsync binary and its own terms are separate from SyncPilot; Windows/macOS ports are not planned deliveries.

Use [official Releases](https://github.com/turlamai/syncpilot/releases), select an explicitly listed OS/architecture asset, read its release notes and check supplied checksums. An absent asset/platform is not a delivery promise. Preview builds may lack publisher signing or notarization; do not disable system-wide security protections to install them.

## Your first successful session

1. Launch with a disposable test folder and confirm the selected daemon binary/version.
2. Connect a second test device through the official UI and verify a small file in each direction.
3. Test daemon stop/restart, login startup and recovery before giving it valuable folders.

## Data, backup and recovery

Quit SyncPilot and stop rslsync before backing up ~/.local/share/site.jrtx.syncpilot, including syncpilot-settings.json, rslsync.conf and storage/. Back up the actual synced files independently. A synced deletion can propagate; sync is not a backup.

## Network, keys and privacy

The UI/control proxy binds to loopback. The official Resilio daemon sends file contents to configured peers and may contact its discovery/relay services. SyncPilot being local does not mean your synced files never leave the machine.

## Known limits

Third-party compatibility, daemon authentication/recovery and installation-specific updates remain tracked in #10. Server/static installs can require operator-managed updates.

## Updates and removal

Back up data and read the destination release notes first. An in-app update check does not necessarily install an update for your channel; follow the manual for portable, installer and source paths. Never bypass a failed signature check or replace the program with an untrusted artifact. On failure, preserve data and the error, then recover with a trusted release. Removing the program does not necessarily erase its separate data directory; verify your backup before deleting personal data.

## Get help

Report problems in [GitHub Issues](https://github.com/turlamai/syncpilot/issues), in English or Chinese. Include the version, OS/architecture, installation channel, steps, expected result and actual result. Reproduce with synthetic input first; do not attach keys, credentials, databases, private source documents or complete logs. Public support has no guaranteed response time.

## Further reading

- [Detailed manual](../docs/guide.html)
- [Updates](../docs/UPDATE.md)
- [Verified daemon interface](../docs/api-verified.md)
- [Project overview and development](../README.md)
- [Current licence](../LICENSE)
