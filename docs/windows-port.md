# Windows Port

Windows support is not implemented. This document defines the expected contribution boundary and acceptance criteria for a future Windows client.

## Product boundary

The Windows application should keep the same four-step workflow as macOS: choose Claude or Codex, enter the relay URL, enter the API key, select enabled and default models, then test and apply. Selecting an already configured client must offer restoration or reconfiguration after scanning the client's actual files.

The first Windows implementation should remain a configuration utility. Local proxying, protocol conversion, provider catalogs, usage tracking, and background services are outside this port.

## Configuration targets to verify

These paths are research starting points and must be confirmed against current Windows releases before support is declared:

- Claude Code: `%USERPROFILE%\.claude\settings.json`
- Claude Desktop normal deployment: `%LOCALAPPDATA%\Claude\claude_desktop_config.json`
- Claude Desktop third-party deployment: `%LOCALAPPDATA%\Claude-3p\claude_desktop_config.json`
- Claude Desktop gateway metadata and profiles: `%LOCALAPPDATA%\Claude-3p\configLibrary\`
- Codex: `%CODEX_HOME%\config.toml` when `CODEX_HOME` is set, otherwise `%USERPROFILE%\.codex\config.toml`

Do not read CC Switch or another manager's database. Preserve unrelated fields in client-owned JSON and TOML files.

## Required behavior

- Scan unmanaged, RelayMate-managed, drifted, missing, and malformed configurations.
- Validate Anthropic Messages for Claude and OpenAI Responses for Codex before writing.
- Fetch `/v1/models`, support horizontal multi-select, and require one enabled default model.
- Configure Claude Code and Claude Desktop together, including third-party deployment selection.
- Generate a Codex model catalog containing exactly the enabled models.
- Save one immutable baseline before the first apply and add newly managed paths without replacing earlier baseline bytes.
- Write files with user-only access where Windows supports it and replace files atomically.
- Restore original contents and original absence exactly; require an explicit override after external drift.
- Explain when Claude or Codex must be fully restarted.

## Verification

A Windows pull request is complete only after automated unit tests and an end-to-end run on a supported Windows version demonstrate:

1. Fresh setup from the normal application entry point.
2. A real minimal request from Claude Code, Claude Desktop, and Codex to an isolated relay.
3. Multiple enabled models and the selected default appearing in each client's model menu.
4. Persistence after fully restarting the target client and RelayMate.
5. Authentication, network, malformed-response, and permission error feedback.
6. Exact restoration for existing files and deletion of files RelayMate created.

Document the Windows UI framework, installer format, minimum OS version, signing status, and reproducible build commands in the pull request.
