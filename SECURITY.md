# Security policy

## Supported versions

Until the first stable release, security fixes are applied to the latest release and the `main` branch only.

| Version | Supported |
|---|---|
| Latest release | Yes |
| `main` | Yes |
| Older snapshots | No |

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability or accidentally exposed credential. Use GitHub's private vulnerability reporting for this repository:

1. Open the repository's **Security** tab.
2. Choose **Advisories** and **Report a vulnerability**.
3. Include the affected version or commit, reproduction steps, expected impact, and any suggested mitigation.

If private reporting is unavailable, open a public issue containing no exploit details or secrets and ask the maintainer to establish a private channel.

Maintainers aim to acknowledge a complete report within seven days. Timelines for validation, remediation, disclosure, and credit depend on severity and the availability of an isolated reproduction.

## Credential exposure

If a real credential was committed, treat it as compromised: revoke or rotate it first, then remove it from the repository and history as appropriate. Deleting a line in a later commit is not sufficient.

## Scope

Examples in scope include secret leakage, unsafe offline-bundle contents, command injection, privilege-boundary bypass, untrusted configuration execution, and vulnerabilities introduced by the project's container or workflow definitions. Upstream Codex, LiteLLM, Docker, model-server, and model vulnerabilities should also be reported to their respective maintainers.
