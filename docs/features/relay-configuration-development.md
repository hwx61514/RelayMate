# Relay Configuration Development

## Scope

Build a macOS SwiftUI utility that configures API relays for Claude Desktop, Claude Code, and OpenAI Codex. The application accepts a relay URL, default model, and API key, validates the endpoint, applies the minimal client-specific configuration, and restores the exact pre-application files.

Out of scope: Windows and Linux, provider catalogs, multiple saved relay profiles, local proxying, MCP, Skills, usage metering, cloud sync, and automatic protocol translation.

## Normal Entry Point

Launch `RelayMate.app`. The main window opens on a guided client-selection step with separate Claude and Codex buttons. New configurations proceed through URL, API key, and model steps. Selecting an already configured client first presents restore and reconfigure actions.

## Guided Setup Revision

- [x] Replace the single-page form with a four-step wizard: client, URL, API key, and model. Verified forward/back navigation, disabled actions, automatic field focus, and accessible progress labels in the rendered app.
- [x] Show existing configuration actions immediately after client selection. Verified relaunch into an `已配置` client, direct restore, and reconfigure navigation with existing URL and key retained; the model step requires a fresh explicit selection.
- [x] Automatically refresh the complete model catalog when entering the model step, retain manual model entry and retry, and require an explicit model selection before applying. Verified with a two-model isolated relay: neither model was preselected, the apply action remained disabled, and selecting `gpt-relay` displayed a checked state and enabled apply.
- [x] Finish with client-specific API validation and atomic apply, then show a clear success result with routes to configure another client or revise the same one. Verified the Codex apply success page, relaunch persistence, management page, and restore from the normal entry point.
- [x] Repackage and visually verify the native app in light mode at its minimum window size. Verified labels, keyboard/default actions, disabled states, no clipping, valid ad-hoc signature, valid plist, and arm64 architecture.

## Live Configuration Scan

- [x] Scan each target client's standard configuration files whenever the app starts or a client is selected; do not read or depend on CC Switch data. Verified unconfigured, external relay, RelayMate managed, drifted, and malformed states with isolated fixtures; the packaged app detected an external Claude Code relay immediately from its isolated `settings.json`.
- [x] Make restore availability depend on a valid RelayMate baseline while still displaying relay configurations created by other tools. Verified the external relay had no restore action, could be reconfigured, returned byte-for-byte after restore, was rescanned as externally managed, and no longer exposed restore.
- [x] Update Codex configuration for current releases, where top-level `profile = "name"` no longer selects a profile file. The active model/provider and owned provider table are written directly into user `config.toml`; unrelated content is retained, the obsolete owned profile is removed, and Codex 0.153.4 loaded the generated provider and sent `/v1/responses` to an isolated relay.
- [x] Clarify that the Claude target covers both Claude Desktop and Claude Code. Verified the rendered client selection and completion copy instruct the user to fully quit and reopen both products.
- [x] Re-run unit, isolated API, relaunch, scan, drift, and restore checks; then rebuild and verify the signed arm64 app bundle. Verified 19 tests, isolated native UI flow, Claude Code 2.1.116 request routing, Codex 0.153.4 provider loading, package signature, plist, and architecture on 2026-09-08.

## Claude Code Runtime URL Compatibility

- [x] Normalize a trailing `/v1` before writing `ANTHROPIC_BASE_URL`, because Claude Code appends `/v1/messages` itself. Verified root, nested, trailing-slash, and non-versioned relay paths while preserving the entered URL for `/v1/models` discovery.
- [x] Make the pre-apply connectivity test construct the same effective endpoint as Claude Code. Verified the accepted test URL and runtime base resolve to the same `/v1/messages` path.
- [x] Run Claude Code 2.1.116 against an isolated normalized configuration and capture the request path, model, and authentication scheme without exposing credentials. The CLI returned `OK` and the relay received `/v1/messages`, `probe-model`, and Bearer authentication; the pre-fix probe reproduced `/v1/v1/messages`.
- [x] Re-run the full test suite, package the app, and verify its signature, plist, architecture, and rendered wizard. Verified 21 tests, the signed arm64 release bundle, and a full isolated Claude flow from RelayMate through Claude Code 2.1.116.

## Claude Desktop Third-Party Deployment

- [x] Extend the Claude choice to configure both Claude Code and the macOS Claude desktop app. Verified the normal and `Claude-3p` deployment files switch to `3p` while preserving unrelated fields.
- [x] Write a RelayMate-owned gateway profile and select it through `Claude-3p/configLibrary/_meta.json`. Verified the profile contains the tested URL, bearer credential, and selected Claude-safe model without reading CC Switch's database.
- [x] Use a lowercase UUID accepted by Claude Desktop for the RelayMate profile, remove the legacy uppercase profile during apply, and preserve the actual case-sensitive path in the original baseline. Verified the selected ID matches Claude's validation rule and legacy file contents and filename casing restore exactly on the default case-insensitive macOS filesystem.
- [x] Include every desktop deployment and profile file in the existing atomic backup, drift detection, and exact restore flow. Verified existing files and files created by RelayMate return to their original state.
- [x] Update the wizard copy so users understand the Claude choice covers both products and must fully quit Claude.app before reopening it.
- [x] Re-run unit tests, package the app, exercise the normal Claude wizard, and verify Claude.app launches with `deploymentMode=3p` and the RelayMate profile selected. Verified 26 tests, successful model discovery and connectivity test, `Claude-3p` process data directory, two renderer processes with `deploymentMode=3p`, visible Gateway mode, selected Claude Opus 5, and a live `OK` response on 2026-09-08.

## Claude Model Allowlist

- [x] Separate Claude's enabled-model allowlist from its default model. Verified the desktop profile writes every checked compatible model to `inferenceModels`, while Claude Code writes one selected default to `ANTHROPIC_MODEL`.
- [x] Make the model step use multi-select checkboxes for Claude and a default-model control constrained to checked models. Verified loading, search, select-all, clear, manual entry, disabled apply, and reconfiguration states in the rendered app.
- [x] Lay out model checkboxes horizontally and wrap whole model items onto the next row at the trailing edge. Verified at the minimum window size that three short models can share a row, names never wrap internally, and each item moves intact when the remaining width is insufficient.
- [x] Read an existing RelayMate desktop allowlist during configuration scanning and preserve it when reopening the wizard. Verified a three-model profile round-trips without collapsing to one model.
- [x] Re-run tests, package RelayMate, apply the live relay's model selection, fully restart Claude Desktop, and verify its model menu exposes more than the default model. Verified 28 tests and an 11-model live allowlist; Claude's menu displayed all 11 entries after restart with Claude Opus 5 retained as default on 2026-09-08.

## RelayMate Branding

- [x] Rename the visible product and packaged application to RelayMate while preserving the backup location. The bundle identifier was later replaced with a neutral project identifier for open-source distribution; `~/Library/Application Support/RelaySetup/` remains unchanged so existing backup records remain discoverable.
- [x] Add a distinctive native macOS application icon with complete standard and Retina sizes. Verified all ten 16 through 1024 pixel representations in the packaged `.icns`, Finder rendering, and the running app's bundle association.
- [x] Update user-facing copy and documentation, then visually inspect the minimum-size window for clipping and consistent naming. Verified the title bar, menu, header, selection page, completion page, and managed-state page all display RelayMate without clipping.

## Automatic Claude 1M Capability

- [x] Preserve an explicit `supports1m` or `supports_1m` boolean from `/v1/models` without inferring capability from the model name. Verified object, string, duplicate, absent, false-valued, and empty catalog entries with parser tests.
- [x] Carry the discovered capability through Claude model selection without adding another wizard control. Verified the wizard applies capability only to an enabled model and omits another capable but unchecked model.
- [x] Write supported Claude Desktop models as `{ "name": "...", "supports1m": true }` and keep ordinary models as strings. Verified default order and mixed profile representation.
- [x] Scan both string and object forms from an existing RelayMate profile and preserve 1M capability on reconfiguration. Verified mixed-profile round-trip behavior.
- [x] Run the project test suite, rebuild the application bundle, and verify its signature, plist, architecture, and packaged 1M behavior. Verified 30 tests, a fresh release executable, valid ad-hoc signature, valid plist, and arm64 architecture on 2026-09-08.

## Codex Enabled Model Catalog

- [x] Replace Codex's vertical default-model list with the same horizontal wrapping checkbox layout used by Claude, plus a default-model selector constrained to enabled models. Verified four short items sharing the first row, a long item moving intact to the second row, multiple checked states, and a checked default in the rendered app.
- [x] Generate a RelayMate-owned Codex `model_catalog_json` containing exactly the enabled models and point the active user configuration to it. Verified Codex 0.153.4 loaded exactly the five selected live models from `relaymate-model-catalog.json`.
- [x] Preserve matching metadata from Codex's own model cache and use a conservative valid Responses template for unknown relay model IDs. Verified known context and verbosity metadata retention, fallback fields, and direct catalog loading with Codex 0.153.4 without reading CC Switch configuration.
- [x] Include the generated catalog in baseline backup, drift detection, atomic apply, and exact restore. Verified reconfiguration scanning, removal of a newly created catalog on restore, and byte-for-byte restoration of an existing pointer and catalog file.
- [x] Re-run tests, rebuild RelayMate, and visually verify the normal Codex wizard at the minimum window size. Verified 32 tests, fresh release packaging, horizontal wrapping, multi-select interaction, default picker, feedback, and action layout on 2026-09-08.

## Beginner Distribution And GitHub Release

- [ ] Add a reproducible macOS DMG builder that packages the current RelayMate app, includes an Applications alias, and presents the familiar drag-to-install Finder window. Verify the mounted image contents, volume layout, signature, plist, and executable architecture.
- [ ] Replace the brief repository landing page with a Chinese-first beginner guide covering the product purpose, supported clients, prerequisites, installation, first launch, four-step setup, restart behavior, restoration, privacy, troubleshooting, development, and Windows status. Verify every documented action matches the current UI and runtime behavior.
- [ ] Update macOS CI to build and validate the distributable DMG and upload it as the primary artifact. Verify workflow syntax and run the same package commands locally.
- [ ] Perform final privacy, secret, repository-content, and release-artifact scans; initialize the public history without local build data or credentials. Verify the commit tree contains only intended files.
- [ ] Create the public GitHub repository, push the verified source, publish the initial release with DMG and SHA-256 checksum, and verify the repository page and downloadable release assets through GitHub's API.

## Saved Relay Platforms

- [ ] Store multiple named relay platforms with URL, API key, and separate Claude/Codex model selections in RelayMate's private application-support directory. Verify persistence, user-only file permissions, per-client selections, and update-in-place behavior.
- [ ] Show saved platforms in the existing URL step, support new, select, rename, and delete actions, and keep deletion independent from active client configuration and original backups. Verify the rendered minimum-size window and confirmation copy.
- [ ] Preserve a relay already detected in Claude or Codex standard configuration as a saved platform before another relay replaces the active values. Verify external active configurations remain selectable after switching.
- [ ] Discover Codex provider tables as optional saved platforms without reading another manager's database or deleting and rewriting unrelated provider tables. Verify providers remain byte-for-byte unchanged unless the user explicitly selects historical-session redirection.
- [ ] Re-run unit, isolated UI, package, DMG, privacy, and release checks before publishing.

## Open Source Preparation

- [x] Replace personal application identifiers and historical references with neutral project-owned values while preserving the existing application-support backup path. Verified tracked-source and packaged-binary scans found no personal names, domains, addresses, or absolute home paths; the bundle identifier is `com.relaymate.desktop` and the compatibility backup path remains unchanged.
- [x] Add an MIT license, contribution guide, security policy, repository attributes, and ignore rules that exclude builds, local client configuration, credentials, logs, and editor metadata. Verified a fresh Git dry-run contains only intended source, tests, resources, and project documentation while `.build/` and `dist/` remain ignored.
- [x] Add a contributor-ready Windows port specification with supported client paths, ownership boundaries, acceptance criteria, and local test requirements. Verified the document explicitly describes Windows as unimplemented and requires end-to-end evidence before support can be claimed.
- [x] Add macOS continuous integration for tests and release packaging, and make packaging independent of the host CPU architecture. Verified the workflow YAML parses successfully and the local script resolves SwiftPM's current binary directory, then produces a valid signed app.
- [x] Run source and packaged-content privacy scans, the complete test suite, package validation, and a clean Git status review before marking the repository ready for publication. Verified 32 tests passed, Gitleaks reported no leaks, targeted source and binary scans returned no matches, and the packaged plist, signature, icon set, bundle identifier, and executable architecture passed validation on 2026-09-08.

## Acceptance Criteria And Work

- [x] Create a native SwiftUI macOS application with Claude Code and Codex selection, URL/model/key fields, validation feedback, and configured-state actions. Verified by launching the packaged app and inspecting initial, model-loaded, configured, relaunched, and restored states through macOS accessibility and a final screenshot.
- [x] Detect each client's standard user-level configuration path without requiring the client to be running. Verified with isolated temporary-home integration tests and an E2E app launched with isolated home/support paths.
- [x] Validate URL syntax and perform a minimal client-specific API request before writing configuration. Verified by URL/endpoint, success, authentication failure, and network error handling tests; the E2E Codex flow performed a real Responses request against a local relay before writing files.
- [x] Fetch and parse the relay's complete `/v1/models` catalog, present it in a searchable native model selector, and retain manual entry when listing is unsupported. Verified with OpenAI/Anthropic catalog fixtures, duplicate/empty filtering, and a rendered two-model catalog; loading leaves the field empty until the user selects or types a model.
- [x] Merge Claude Code relay values into `~/.claude/settings.json` while preserving unrelated JSON fields. Verified with a fixture containing unrelated environment and permission values.
- [x] Configure Codex through an owned provider in the active user-level `~/.codex/config.toml` and preserve unrelated content. Verified with unit fixtures showing original comments and MCP tables retained, plus Codex 0.153.4 loading the generated provider without `--profile`.
- [x] Save exact original file contents and existence metadata before first application, use private permissions and atomic replacement, and never replace the baseline during later edits. Verified by byte-for-byte restore and missing-file tests.
- [x] Detect configuration drift before restoration and require an explicit force restore if managed files changed externally. Verified by status and restore-conflict tests.
- [x] Surface actionable success, loading, validation, network, malformed response, and restore-conflict states. Verified through state-model tests and rendered success/recovery states; native controls expose labels and disabled/loading state through accessibility.
- [x] Keep the pre-apply connectivity test from reporting a transient gateway fault as an incompatible relay: retry once on a timeout or a transient 5xx, always keep the HTTP status code in the error even when the relay returns an empty body, and give a Chat Completions-only relay a specific diagnostic instead of a generic failure. Verified with unit tests over an injected sender and with live probes: the real relay applied successfully and still wrote `wire_api = "responses"`; a local relay answering `/v1/responses` with 404 and `/v1/chat/completions` with 200 produced the "换用提供 Responses 接口的中转线路" message after probing both endpoints in that order; a local relay returning a 554 with a 0-byte body and then 200 was retried once and applied silently. `wire_api = "chat"` is never written, because current Codex releases reject that value while parsing `config.toml`.
- [x] Package a runnable macOS `.app` and document local build and installation. Verified with a full isolated fetch, explicit model selection, apply, relaunch, and restore workflow. The restored main config matched the original content and the owned profile was deleted.

## Verification Record

- Status: completed and verified on macOS, 2026-09-08.
- `swift test --disable-sandbox`: 37 tests passed, 0 failures.
- Isolated native UI: external scan, no-baseline restore suppression, fresh model selection, apply, relaunch, managed-state detection, exact restore, and external-state recovery passed.
- Client integration: the packaged RelayMate app normalized an entered `/v1` URL, then Claude Code 2.1.116 sent the selected model to `/v1/messages` and returned `OK`; Claude Desktop 1.46388.4 launched from `Claude-3p` in Gateway mode, displayed all 11 checked models with Claude Opus 5 as default, and returned `OK`; explicit 1M model metadata now round-trips through the wizard and Claude Desktop profile while unchecked and unmarked models stay unchanged; Codex 0.153.4 loaded the active owned provider, sent the configured model to `/v1/responses`, and loaded exactly the five enabled models from RelayMate's generated catalog.
- Release package: `dist/RelayMate.app`, ad-hoc signature valid, `Info.plist` valid, arm64 executable, complete `.icns` rendered by Finder.
- Distribution limitation: the app is ad-hoc signed and has not been Apple Developer signed or notarized.

## Affected Layers

- SwiftUI application and state model
- Relay protocol validation client
- Claude Code JSON configuration adapter
- Codex active TOML provider configuration adapter
- Atomic file writer and restoration store
- macOS application packaging

## Compatibility And Recovery

Claude support targets `~/.claude/settings.json` plus Claude Desktop's normal and `Claude-3p` deployment files and its selected RelayMate gateway profile. Codex support targets the user-level `$CODEX_HOME/config.toml`; a legacy Relay Setup profile file is removed when present. Existing unrelated configuration remains owned by the user. The historical `~/Library/Application Support/RelaySetup/` backup location is intentionally preserved so upgrades to RelayMate can still restore earlier baselines. Original bytes and filename casing are retained until restoration succeeds; malformed files or external drift stop automatic replacement and show a recoverable error.
