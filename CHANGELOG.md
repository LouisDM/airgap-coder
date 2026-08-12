# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and releases use semantic versioning.

## [Unreleased]

### Added

- English project entry point and expanded contributor documentation.
- Security policy, threat model, compatibility policy, and opt-in adopter registry.
- Release, supply-chain, and local Codex review foundations.
- Documentation index, offline deployment guide, and troubleshooting guide.

### Changed

- Rebuilt the English and Simplified Chinese READMEs around equivalent quick starts, security boundaries, verified scope, and community navigation.
- Clarified the host-side and isolated-container Codex runtime paths.
- Aligned offline deployment guidance with default validated-registry inclusion and the `--no-registry` opt-out.
- Limited the compatibility matrix to reproducible reports with explicit evidence.
- **Breaking:** `lc code` and the container entrypoint now refuse to start Codex when a `.env` is present in the workspace it will run in, instead of warning and proceeding. Codex runs with `approval_policy = "never"` on the host and `danger-full-access` in the container, so a `.env` in the workspace is readable by one model-issued `cat`; both reported instances of that exposure were on documented happy paths, where a single warning line is easy to scroll past or lose in model output. Pass `--allow-workspace-secrets` on the host or `-e AIRGAP_ALLOW_WORKSPACE_SECRETS=1` in the container to allow it explicitly — reviewing airgap-coder itself remains a supported workflow, and the override still prints the full warning. Anyone who ran `lc code` from the airgap-coder directory now needs either the flag or a `cd` into their own project. The offline bundle's generated `install.sh` no longer ends by suggesting `./bin/lc code` in the bundle directory — the line right above it runs `lc init`, which writes the `.env` that would be refused — and instead prints an absolute-path invocation to run from your own project.

### Fixed

- `lc code` and `lc e2e` no longer hand the entire `.env` to the Codex process. Codex runs with `approval_policy = "never"`, so every upstream API key, private endpoint, and custom header value — including those of upstreams the selected profile does not use — was readable by a single model-issued `env`. Both paths now inject only the variables the generated Codex configuration declares through `env_key`, matching what the container entrypoint already did, and fail with a clear message when that value is missing instead of producing a gateway `401`.
- The gateway port asked for by `lc init` now takes effect everywhere. `registry.json`'s `gateway_port` is the single source: `lc` injects it into the Compose environment, and `lc test` reads it instead of assuming `4000`. Previously a non-default port produced a machine where `lc status` reported the gateway dead while `lc test` reached it, because the container was published on the `.env` value. `GATEWAY_PORT` is gone from `.env.example`.
- Offline bundle names and the development image tag now use airgap-coder's own `VERSION` instead of the pinned Codex version, so successive releases no longer collide on a single `airgap-coder:0.145.0` tag in an isolated environment. The Codex baseline moved to an image label and a dedicated manifest line.
- The documented container command no longer mounts the current directory into the workspace. Every example followed `lc init`, which writes `.env` into that same directory, so the copy-paste path handed all upstream endpoints and credentials to a session running under `danger-full-access`. Examples now name an explicit project directory, the entrypoint warns when it finds a `.env` in the workspace without blocking, and a metadata test keeps the examples from drifting back.
- `lc up` now stops immediately when `docker compose up` fails, reports the exit code instead of pointing at an empty `lc logs`, and exits non-zero when the gateway never becomes reachable.
- `LC_GATEWAY_WAIT` is now a wall-clock budget rather than a probe count, so an unreachable gateway behind a packet-dropping firewall no longer takes six times the advertised limit.
- Doctor probe tests now isolate their fake Codex executable from a host installation.
- Container entrypoint now passes exec-only flags after the `codex exec` subcommand.
- Export image-reference tests now expand pinned image variables safely under Bash 3.2.

## [0.1.0] - 2026-08-11

### Added

- `lc` CLI for generating Codex and LiteLLM configuration.
- Multiple upstream profiles with secret values isolated in `.env`.
- Protocol, tool-calling, doctor, end-to-end, export, and secret-invariant tests.
- Checksummed offline export bundles with container-image digests.

[Unreleased]: https://github.com/LouisDM/airgap-coder/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/LouisDM/airgap-coder/releases/tag/v0.1.0
