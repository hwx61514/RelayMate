# Contributing to RelayMate

RelayMate is intentionally small: it scans the supported clients' normal user configuration, validates a relay, applies the minimum required settings, and restores the exact original files. Changes should preserve that guided workflow and avoid adding a provider marketplace or background proxy.

## Development setup

The macOS application requires macOS 13 or later and Xcode 15 or later.

```bash
swift test --disable-sandbox
scripts/package-dmg.sh
```

The packaged application, DMG, and checksum are written to `dist/`.

## Privacy rules

Never commit real API keys, relay URLs, user configuration files, backup data, logs, home-directory paths, signing certificates, or screenshots containing private account data. Use reserved examples such as `https://relay.example/v1` and placeholder keys such as `test-key` in tests and documentation.

RelayMate must not read or depend on another configuration manager's database. Client state should be discovered from the supported client's documented or verified configuration files.

## Pull requests

Keep each pull request focused on one user-visible outcome. Include:

- The problem and resulting behavior.
- Tests for configuration writes, scanning, and exact restoration when those paths change.
- Runtime evidence when client compatibility changes.
- Screenshots for visible interface changes at the minimum window size.
- Documentation updates for changed paths, formats, or supported platforms.

Run the full test suite and package validation before requesting review. Do not describe a platform or client as supported until its normal setup, restart, failure recovery, and restoration paths have been exercised.

## Windows contributions

Windows support is a separate implementation track. Read [docs/windows-port.md](docs/windows-port.md) before starting so the user flow and configuration ownership remain compatible with the macOS application.
