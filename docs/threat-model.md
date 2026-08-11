# Threat model

This document defines the security boundaries airgap-coder intends to preserve. It is not a formal security audit.

## Assets

- upstream and gateway credentials;
- private endpoint topology and custom header values;
- proprietary source mounted into the Codex container;
- prompts, model outputs, tool calls, and gateway logs;
- integrity of source and images transferred into the isolated network.

## Trust assumptions

The operator trusts the host operating system, Docker daemon, selected container images, LiteLLM deployment, model service, and the Codex version being run. The model is not trusted to produce safe commands or correct code. Review and sandbox controls remain necessary.

## Threats and mitigations

| Threat | Project mitigation | Operator responsibility |
|---|---|---|
| Credential committed to Git | Secret values are written to ignored `.env`; tests enforce the registry boundary | Review staged changes and rotate any exposed credential |
| Secret included in offline export | Export starts from `git ls-files`; regression tests reject local secret/state files | Inspect the manifest and use an approved transfer process |
| Moving image tag changes content | Export records image digests; runtime images are pinned where maintained | Mirror and scan approved images; verify checksums and digests |
| Prompt/source disclosure | No project telemetry; gateway remains operator-controlled | Audit gateway/model logging, retention, and access control |
| Malicious model tool call | Protocol tests verify function-calling shape, not intent | Use Codex sandboxing, least privilege, review diffs, and avoid mounting unrelated data |
| Credential read out of the agent's own process environment | `lc code` and `lc e2e` pass only the environment variables the generated Codex configuration declares (`env_key`), not the whole `.env`; the container entrypoint already passed only the gateway key. A regression test asserts that no `KEY_*` upstream credential reaches the Codex process | Keep unrelated secrets out of the shell that launches `lc`; the `.env` file itself stays readable to any process running as you, so do not start Codex in a workspace where reading it is acceptable |
| Malicious repository instructions | None can make an untrusted repository safe automatically | Review repository instructions before running Codex; use a disposable worktree/container |
| Dependency or workflow compromise | CI actions and runtime images are pinned; automated update PRs are reviewable | Review update diffs and provenance before merging or mirroring |
| Compromised transfer media | Bundle checksums detect accidental or post-build modification | Establish trusted signing, custody, and malware-scanning procedures appropriate to the environment |

## Explicit non-goals

airgap-coder does not provide a hardened container sandbox, content filtering, model safety evaluation, host endpoint protection, secret manager, network firewall, image registry, artifact-signing PKI, or defense against a compromised Docker daemon or host administrator.

## Safe deployment checklist

1. Use an isolated staging worktree with no real `.env` in version control.
2. Pin and mirror reviewed images and source releases.
3. Limit gateway/model access to the required network identities.
4. Disable or tightly control prompt and request logging.
5. Mount only the intended workspace into Codex.
6. Run `lc doctor`, `lc test`, and a disposable `lc e2e` fixture before using production source.
7. Review the bundle manifest and checksums on both sides of the transfer boundary.
