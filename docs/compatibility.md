# Compatibility policy

Compatibility is a tested matrix, not a claim that every OpenAI-compatible endpoint works.

## Maintained baseline

| Component | Baseline | Status |
|---|---|---|
| Codex CLI | 0.145.0 | Pinned in the development image |
| Python | 3.9+ | Required by `bin/lc` and test scripts |
| LiteLLM | Pinned container digest in `docker-compose.yml` | Responses-to-Chat-Completions bridge |
| Docker Compose | Current Compose plugin | Gateway lifecycle and integration tests |

The repository's GPU-free integration test uses a deterministic mock Chat Completions server. It proves request translation and response shape, but not the quality or tool-calling reliability of a real model.

## Reporting a real backend

Open a compatibility-report issue or pull request with:

- airgap-coder commit or release;
- Codex CLI version;
- LiteLLM image digest;
- inference server and exact version;
- model identifier and quantization, if any;
- tool parser and chat-template settings;
- context-window settings;
- results of `lc doctor`, `lc test`, and `lc e2e` with secrets removed.

Maintainers may list a backend as:

- **verified**: a reproducible report passes protocol and end-to-end checks;
- **partial**: basic requests pass but tool calling or multi-turn behavior is unreliable;
- **known incompatible**: a reproducible failure is understood;
- **unverified**: configuration guidance exists without a reproducible report.

## Current verified reports

| Backend | Model | Result | Evidence |
|---|---|---|---|
| GPU-free mock server | Deterministic fixture | Bridge verified | [`scripts/test-litellm-bridge.sh`](../scripts/test-litellm-bridge.sh) in CI |

Informal maintainer experiments are not listed as verified backends until they include the exact versions and redacted evidence required above. No entry is an endorsement. Results may change across model, template, parser, inference-server, and Codex versions.

For common failure patterns, see [troubleshooting](troubleshooting.md).
