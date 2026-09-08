# RelayMate

[简体中文](README.md) · English

RelayMate is a compact native macOS utility for configuring an API relay in Claude Desktop, Claude Code, or OpenAI Codex. It validates the selected protocol before writing configuration and can restore the exact files that existed before the first application.

The app guides setup in four steps: choose Claude or Codex, enter the relay URL, enter the API key, then choose models. The model step automatically reads the relay's complete `/v1/models` catalog. For both clients, check every model that should appear in the model menu and choose one checked model as the default. Claude Code uses Claude's selected default. When the catalog explicitly marks a Claude model with `supports1m` or `supports_1m`, RelayMate also enables that capability in Claude Desktop without adding another setup choice. Models without explicit metadata are left unchanged. For Codex, RelayMate writes a private model catalog containing exactly the checked models and references it from `config.toml`. Manual model entry remains available.

Selecting a client scans that client's standard configuration file. RelayMate distinguishes an existing relay created elsewhere from a configuration it manages itself. Existing relay details can be reused for reconfiguration, while restore is offered only after RelayMate has saved a valid baseline.

RelayMate does not read, import, or depend on CC Switch data.

RelayMate is open source under the MIT License. It does not include provider presets, relay credentials, analytics, or telemetry.

## Supported clients

- Claude Desktop and Claude Code through the Anthropic Messages protocol
- OpenAI Codex through the OpenAI Responses protocol

Codex relays must implement the Responses API. Chat Completions-only endpoints are rejected by the connectivity test, which says so explicitly instead of reporting a generic failure: when `/v1/responses` looks absent but `/v1/chat/completions` answers, the error names the missing protocol and asks for a relay that provides Responses. Current Codex releases have removed `wire_api = "chat"`, so RelayMate never writes it. A transient gateway failure is retried once, and every remaining failure keeps its HTTP status code in the message even when the relay returns an empty body.

## Build

Requirements: macOS 13 or later and Xcode 15 or later.

```bash
chmod +x scripts/package-app.sh
scripts/package-app.sh
```

The packaged application is written to `dist/RelayMate.app`.

Run the test suite with:

```bash
swift test --disable-sandbox
```

The current application targets macOS. Windows support is not implemented yet; the contributor specification is in [docs/windows-port.md](docs/windows-port.md).

## Configuration and recovery

Claude Code configuration is merged into `~/.claude/settings.json`. Claude Desktop is switched to its third-party deployment mode and receives a RelayMate-owned gateway profile under `~/Library/Application Support/Claude-3p/`; fully quit Claude before reopening it. Codex writes the active model and owned relay provider directly into `~/.codex/config.toml`, plus a RelayMate-owned model catalog under the same directory; `CODEX_HOME` is respected when set.

For Claude Code, a URL ending in `/v1` is normalized before it is written because Claude Code appends `/v1/messages` itself. Model discovery still uses the entered relay URL's `/v1/models` endpoint.

Each Codex conversation remembers the provider *name* it was created with, and the address is looked up from `config.toml` at request time, so pointing Codex at a new relay only affects new conversations. The URL step therefore lists the other providers already present in `config.toml` together with how many stored sessions reference each one, and pre-checks the ones that are actually in use. A checked provider's table is replaced wholesale with the new relay's settings — only its display `name` is kept, because leftover keys such as `requires_openai_auth` would conflict with the new route. The table lives in `config.toml`, which is already backed up, so a restore undoes this along with everything else. Claude needs no equivalent: both Claude Desktop and Claude Code read a single process-wide configuration, so old conversations follow the new relay after a restart.

Original files are stored privately under `~/Library/Application Support/RelaySetup/`. A restore proceeds immediately when managed files still match the last applied version. External changes require explicit confirmation before restoring the original bytes.

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request. Please report security issues privately using the process in [SECURITY.md](SECURITY.md).
