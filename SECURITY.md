# Security Policy

## Reporting a vulnerability

Please use the repository's **Security** tab and choose **Report a vulnerability** to send a private report. Do not include API keys, complete user configuration files, or other credentials in an issue, discussion, pull request, screenshot, or test fixture.

Include the affected version, platform, reproduction steps, impact, and a minimal redacted example. Public issues are appropriate only after a fix is available or the report has been confirmed to contain no sensitive details.

## Sensitive data handled by RelayMate

RelayMate writes relay credentials to the configuration files required by Claude or Codex and stores exact restoration baselines in the current user's application-support directory. These files must remain private to the user account. Contributions that add logging, diagnostics, exports, crash reporting, or telemetry must prove that URLs, credentials, request bodies, and original configuration bytes cannot be disclosed.
