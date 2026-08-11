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

### Fixed

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
