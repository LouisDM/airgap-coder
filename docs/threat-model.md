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
| Credential read out of the Codex workspace | `lc code` warns when the `.env` it uses lies inside the directory Codex will run in, naming the file and the number of exposed upstreams; the container entrypoint warns when a `.env` is present in the mounted workspace. Both warn rather than refuse (see [Credentials in the Codex workspace](#credentials-in-the-codex-workspace)) | Run `lc code` from your own project directory and mount your own project into the container — not the airgap-coder directory or an unpacked offline bundle |
| Malicious repository instructions | None can make an untrusted repository safe automatically | Review repository instructions before running Codex; use a disposable worktree/container |
| Dependency or workflow compromise | CI actions and runtime images are pinned; automated update PRs are reviewable | Review update diffs and provenance before merging or mirroring |
| Compromised transfer media | Bundle checksums detect accidental or post-build modification | Establish trusted signing, custody, and malware-scanning procedures appropriate to the environment |

## Credentials in the Codex workspace

`lc code` starts Codex in the **current working directory**, and the generated profile sets `approval_policy = "never"` with `sandbox_mode = "workspace-write"`. Two consequences follow.

First, `.env` is an ordinary file. Its `0600` mode stops other users on the host; it does not stop a Codex process running as you. If the working directory is the airgap-coder directory — or any directory above it — then `.env` is inside the workspace, and one `cat .env` discloses every upstream endpoint, credential, and private header value, including those of upstreams the current profile does not use. The value can then be copied into a workspace file, a patch, or a session log. Passing only the declared `env_key` into the Codex process closes the process-environment path; it does not close this one.

Second, `workspace-write` bounds writes, not reads. Codex may read files elsewhere on the host, so relocating `.env` narrows the exposure rather than removing it. A hardened sandbox is an explicit non-goal of this project.

airgap-coder warns instead of refusing. When the `.env` it uses lies inside the directory Codex will run in, `lc code` prints a warning that names the file, states how many upstream credentials it holds, and gives the way to avoid it. It does not print any secret value, and it does not block: running Codex against the airgap-coder checkout itself is a supported workflow (see [Codex workflow](codex-workflow.md)), refusing would break it, and an override flag would become permanent for anyone who adds it — the same exposure with one extra step.

The reliable mitigation is directory separation. The tool directory and your working directory are different things: `cd` into your own project and run `lc code` from there, and the checkout's `.env` is outside the workspace entirely.

### The container path has the same exposure, with less margin

The container passes only `LITELLM_MASTER_KEY` into Codex, so the process-environment path is closed there too. The workspace path is not, and three things make it worse than the host path.

First, the permission level is higher. The entrypoint generates `sandbox_mode = "danger-full-access"` and `codex exec` additionally runs with `--dangerously-bypass-approvals-and-sandbox`, because Codex's Landlock/seccomp sandbox fails to initialize under many container runtimes. That trade is deliberate — the container is the isolation boundary — but it assumes the mount contains only what the session should see. The host path at least keeps `sandbox_mode = "workspace-write"`.

Second, mounting the current directory cancels the entrypoint's credential hygiene. Passing just the gateway key is undone by a mount that delivers the whole `.env` file, including upstreams the session does not use — and the natural way to write the command, mounting whatever directory you happen to be standing in, is exactly the directory `lc init` writes to.

Third, the `lc code` warning cannot fire here: it lives in `bin/lc`, and the container path never runs `lc`. The container therefore needs its own check, and the entrypoint performs it — when a `.env` exists in the workspace it will run in, it writes a warning to stderr naming the path and the permission level, prints no values, and proceeds. Under non-interactive `codex exec` that line is easy to lose in model output, so it is a clue for whoever already stepped on this, not the primary control.

The primary control is the mount. Mount the project Codex should work on; do not mount the airgap-coder checkout or an unpacked offline bundle, both of which hold the `.env` that `lc init` just wrote.

## Explicit non-goals

airgap-coder does not provide a hardened container sandbox, content filtering, model safety evaluation, host endpoint protection, secret manager, network firewall, image registry, artifact-signing PKI, or defense against a compromised Docker daemon or host administrator.

## Safe deployment checklist

1. Use an isolated staging worktree with no real `.env` in version control.
2. Pin and mirror reviewed images and source releases.
3. Limit gateway/model access to the required network identities.
4. Disable or tightly control prompt and request logging.
5. Mount only the intended workspace into Codex — never the airgap-coder directory or an unpacked bundle, which contain `.env`.
6. Run `lc doctor`, `lc test`, and a disposable `lc e2e` fixture before using production source.
7. Review the bundle manifest and checksums on both sides of the transfer boundary.
