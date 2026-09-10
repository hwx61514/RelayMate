# Windows Port

RelayMate now contains a separate C# + WinUI 3 Windows client under `windows/`. The macOS SwiftUI application remains unchanged. Both clients implement the same configuration, validation, immutable-baseline backup, drift detection, and exact-restore semantics.

## Supported architecture

The primary Windows artifact is a self-contained **32-bit x86** application (`win-x86`). The project also declares `x64`/`win-x64` so a 64-bit build can be produced from the same source.

Windows builds must run on Windows because the WinUI XAML compiler is itself a Windows executable. The repository CI uses `windows-2025` and verifies the produced PE machine field (`0x014c` for x86) before uploading the artifact.

## Projects

- `windows/RelayMate.Core`: platform paths, JSON/TOML configuration adapters, relay connectivity tests, secure atomic file writes, Windows ACL handling, backup/restore, and saved relay storage.
- `windows/RelayMate.Windows`: the WinUI 3 desktop interface.
- `windows/RelayMate.Core.Tests`: dependency-free executable tests that also run on macOS and Linux.
- `windows/RelayMate.Windows.sln`: Visual Studio solution.

## Build x86

Requirements:

- Windows 10 version 1809 or later, or Windows 11
- .NET 10 SDK
- Network access to restore the official `Microsoft.WindowsAppSDK` NuGet package

From PowerShell:

```powershell
scripts/package-windows.ps1 -Architecture x86
```

Outputs:

```text
dist/RelayMate-Windows-x86.exe
dist/RelayMate-Windows-x86.exe.sha256
dist/RelayMate-Windows-x86/
dist/RelayMate-Windows-x86.zip
dist/RelayMate-Windows-x86.zip.sha256
```

The primary artifact is a self-contained single executable. It bundles the .NET and Windows App SDK payload and extracts native WinUI dependencies to the current user's temporary directory at launch. The publish directory and ZIP are retained for inspection and troubleshooting.

Startup exceptions are displayed in a native error dialog and written to `%LOCALAPPDATA%\RelayMate\logs\startup.log`. The packaging script sets the final executable name through the app project's conditional MSBuild `AssemblyName`; it must not publish under one name and rename the EXE afterward, because WinUI single-file XAML resource lookup is filename-sensitive. If the process exits before managed startup diagnostics can initialize, inspect Windows Event Viewer under **Windows Logs → Application**.

A 64-bit build is also available:

```powershell
scripts/package-windows.ps1 -Architecture x64
```

## Configuration paths

The Windows client uses:

- Claude Code: `%USERPROFILE%\.claude\settings.json`
- Claude Desktop normal deployment: `%LOCALAPPDATA%\Claude\claude_desktop_config.json`
- Claude Desktop third-party deployment: `%LOCALAPPDATA%\Claude-3p\claude_desktop_config.json`
- Claude Desktop gateway metadata and profiles: `%LOCALAPPDATA%\Claude-3p\configLibrary\`
- Codex: `%CODEX_HOME%\config.toml` when `CODEX_HOME` is set, otherwise `%USERPROFILE%\.codex\config.toml`
- RelayMate backups: `%LOCALAPPDATA%\RelayMate\`

Tests can override these roots with `RELAY_SETUP_HOME`, `RELAY_SETUP_LOCALAPPDATA`, and `RELAY_SETUP_SUPPORT_DIR`.

## Security and recovery

Configuration files are written through a temporary file in the destination directory and atomically replaced. On Windows, RelayMate applies a user-only ACL to new private files and stores the original discretionary ACL (DACL) in the immutable baseline so restoration can reinstate it without requiring elevated Windows privileges.

Before the first apply, RelayMate records the original bytes or original absence of every managed file. Subsequent external drift is detected by SHA-256. A normal restore refuses to overwrite drift; the UI requires an explicit confirmation before forcing restoration.

## Release verification still required

Before publishing a signed Windows release, run an end-to-end check on the minimum supported Windows version and confirm:

1. Claude Code, Claude Desktop, and Codex read the documented Windows paths.
2. A real request reaches an isolated relay for both supported protocols.
3. Multiple enabled models and the selected default appear after fully restarting each client.
4. Existing unrelated JSON/TOML fields survive apply.
5. Restore reproduces original bytes, absence, and Windows DACLs.
6. The final archive is code-signed or its unsigned status is clearly documented.
