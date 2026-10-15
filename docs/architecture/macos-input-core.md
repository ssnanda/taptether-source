# macOS Input Core

TapTether separates network-facing agent updates from the executable that owns
macOS Accessibility approval.

## Components

- `~/.local/bin/taptether-input-core` is the stable CoreGraphics event process.
  Its version is recorded in `INPUT_CORE_VERSION`. Routine agent installation,
  repair, and update operations preserve the installed file byte-for-byte.
- `~/.local/bin/taptether-agent` continues to authenticate phones, terminate
  TLS, discover peers, and process application commands. On macOS it delegates
  validated input events to the core.
- `~/Library/Application Support/taptether/input-core/input.sock` is a mode
  `0600` Unix-domain socket inside a mode `0700` directory. Requests also need
  the random mode `0600` `ipc.token`. The core accepts only the same macOS user
  from the fixed, user-owned, non-group/world-writable installed agent path.

The phone-to-agent authentication and pairing files are unchanged.

## Installation and migration

The first split-core installation copies the core to its stable path, creates
the IPC token, and loads `com.taptether.input-core` before the agent. Legacy
five-file agent archives remain unchanged so old updaters still accept them.
During the one-time migration, the new controller retrieves the separately
published Input Core archive over HTTPS and verifies GitHub's SHA-256 asset
digest before installation. The Finder app bundle includes the same core and
does not require that bootstrap download.

The user must add `~/.local/bin/taptether-input-core` to System Settings >
Privacy & Security > Accessibility once. Old `taptether-agent` entries may be
removed manually. TapTether never edits or resets the TCC database.

An Input Core upgrade is deliberately separate from an agent update and must
name the expected version:

```sh
taptetherctl-mac upgrade-core --authorize VERSION
```

Replacing the core may require Accessibility approval again. Routine agent
updates neither execute this command nor package the core in the legacy agent
tarball.

## Signing requirement

Release builds should set `TAPTETHER_CODESIGN_IDENTITY` to the same persistent
Developer ID Application certificate for every supported architecture and
every release. The build defaults to ad-hoc signing only for local development.
Ad-hoc signatures are not a durable production identity and must not be relied
on to preserve TCC approval. Notarization should be added before public
distribution under a Developer ID certificate.

Even with persistent signing, preserving the installed Input Core is the
primary stability guarantee. A core is rebuilt and replaced only for a real
core functionality or security change, after explicit user authorization.
