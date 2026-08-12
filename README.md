<div align="center">

# airgap-coder

**Run Codex CLI with self-hosted models in air-gapped or restricted networks.**

[**English**](README.md) · [简体中文](README.zh-CN.md)

[![CI](https://github.com/LouisDM/airgap-coder/actions/workflows/ci.yml/badge.svg)](https://github.com/LouisDM/airgap-coder/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/LouisDM/airgap-coder?display_name=tag)](https://github.com/LouisDM/airgap-coder/releases/latest)
[![License](https://img.shields.io/github/license/LouisDM/airgap-coder)](LICENSE)

[Quick start](#quick-start) · [Documentation](docs/README.md) · [Compatibility](docs/compatibility.md) · [Discussions](https://github.com/LouisDM/airgap-coder/discussions)

</div>

airgap-coder connects the OpenAI Codex CLI to vLLM, SGLang, and other self-hosted Chat Completions services through a pinned LiteLLM gateway. Its zero-dependency `lc` management CLI generates configuration, keeps private values out of Git, validates tool calling, and builds checksummed offline deployment bundles.

```text
Codex CLI --Responses API--> LiteLLM --Chat Completions--> self-hosted model
 host or container              gateway                    private GPU network
```

> [!IMPORTANT]
> airgap-coder does not include a model or inference server. Your exact model, chat template, tool parser, inference-server version, and Codex version must pass `lc doctor`, `lc test`, and `lc e2e` together.

## Why airgap-coder

Modern Codex releases use the Responses API, while many self-hosted inference stacks expose Chat Completions. A working HTTP endpoint is not enough: coding agents also depend on reliable function calling, correct context limits, and consistent configuration across machines.

airgap-coder provides:

- **Protocol translation** — a pinned LiteLLM gateway converts Responses requests into Chat Completions requests.
- **Secret separation** — endpoints, API keys, and private header values stay in an ignored, mode-`0600` `.env` file.
- **Team-safe configuration** — `registry.json` stores model structure and environment-variable names, not resolved private values.
- **Behavioral diagnostics** — `lc doctor`, `lc test`, and `lc e2e` distinguish connectivity from usable tool calling.
- **Offline delivery** — `lc export` packages tracked source, container images, a manifest, and checksums for approved transfer.
- **Deterministic checks** — CI validates secret invariants and the Responses-to-Chat-Completions bridge without a GPU, real model, or OpenAI API key.

## Quick start

### Run Codex on the host

Requirements: Python 3.9+, Docker with the Compose plugin, and Codex CLI `0.145.0`.

```bash
git clone https://github.com/LouisDM/airgap-coder.git
cd airgap-coder
npm install -g @openai/codex@0.145.0

./bin/lc init    # configure a self-hosted upstream
./bin/lc up      # start the LiteLLM gateway
./bin/lc test    # validate protocol and tool calling
```

Then start Codex from the project you want to work on. The tool directory and your working directory are different things:

```bash
cd ~/your-project
~/airgap-coder/bin/lc code    # start Codex with the selected upstream
```

> [!IMPORTANT]
> `lc code` runs Codex in the current directory under `approval_policy = "never"`, so the model can read that directory without asking. Starting it inside the airgap-coder directory puts `.env` — every upstream endpoint and credential — in reach of a single `cat`. `lc code` warns when it detects this, but does not block it, because reviewing airgap-coder itself is a supported workflow. See [Credentials in the Codex workspace](docs/threat-model.md#credentials-in-the-codex-workspace).

`lc init` asks for the upstream URL, credential, model ID, context window, and backend family. Resolved endpoints and credentials are written only to `.env`; the shareable structure is written to `registry.json`.

This path does **not** require an `OPENAI_API_KEY`. It uses your self-hosted model credential instead. Maintainers can also run [read-only local Codex review](docs/codex-workflow.md) with an existing ChatGPT sign-in.

### Run Codex from the isolated container

Build the pinned image on a connected staging machine, transfer it through your approved process, then point it at the internal gateway:

```bash
docker run --rm -it -v "$PWD:/workspace" \
  -e GATEWAY_URL=http://gateway.your-intranet.local:4000/v1 \
  -e GATEWAY_KEY=your-gateway-key \
  -e MODEL=your-model \
  airgap-coder:0.1.0 exec "inspect this repository"
```

See the complete [offline deployment guide](docs/offline-deployment.md) before crossing a network boundary.

## How it works

1. `lc init` or `lc add` writes private values to `.env` and non-secret model structure to `registry.json`.
2. `lc sync` generates ignored LiteLLM and Codex configuration from those two sources.
3. LiteLLM accepts `/v1/responses` from Codex and sends `/v1/chat/completions` to the selected upstream.
4. `lc test` checks the protocol bridge and tool-call shape; `lc e2e` verifies that Codex can perform a controlled code edit.
5. `lc export` creates a self-contained deployment bundle for an isolated environment.

Read [architecture](docs/architecture.md) for components and trust boundaries.

## Command reference

| Command | Purpose |
|---|---|
| `lc init` | Configure the first upstream interactively |
| `lc add`, `lc rm <name>`, `lc ls` | Manage upstream definitions |
| `lc use <name>` | Select the default upstream |
| `lc up`, `lc down`, `lc status`, `lc logs` | Manage the gateway |
| `lc test [name]` | Run protocol and tool-calling checks |
| `lc e2e [name]` | Ask Codex to edit a fixture and verify the result |
| `lc code [...]` | Start host-side Codex with the selected upstream |
| `lc doctor` | Diagnose versions, proxy settings, connectivity, and tool calling |
| `lc sync` | Regenerate LiteLLM and Codex configuration |
| `lc migrate` | Move legacy plaintext header values into `.env` |
| `lc export [--no-images] [--no-registry]` | Create a checksummed, self-contained offline bundle |
| `lc version` | Print the airgap-coder version |

Run `./bin/lc help` for the built-in reference.

## Backend requirements

The upstream must expose an OpenAI-compatible Chat Completions endpoint and return structurally valid function calls. A typical vLLM launch includes:

```bash
--enable-auto-tool-choice --tool-call-parser hermes --max-model-len 131072
```

For Qwen-family models, disabling thinking mode commonly improves tool-call parsing. airgap-coder supports both common parameter shapes:

- vLLM/SGLang: `chat_template_kwargs: {"enable_thinking": false}`
- hosted gateways: top-level `enable_thinking: false`

These are starting points, not universal compatibility claims. Validate the exact deployment and submit reproducible results through the [compatibility report](https://github.com/LouisDM/airgap-coder/issues/new?template=compatibility.yml).

## Security boundaries

- `.env`, generated Codex profiles, and generated LiteLLM configuration are ignored by Git.
- Offline export includes tracked source and a validated `registry.json` by default, while excluding `.env`, generated configuration, Git history, and local Codex state. Export refuses legacy plaintext header values; `--no-registry` creates a generic bundle without the registry.
- Release source archives include SHA-256 checksums and GitHub build provenance attestations.
- airgap-coder has no telemetry, but the model service, gateway, container runtime, and Codex runtime remain separate trust boundaries and may have their own logging behavior.
- A checksummed bundle proves integrity, not that its contents are approved for a particular isolated environment.

Read the full [threat model](docs/threat-model.md) and [security policy](SECURITY.md). Report vulnerabilities privately through [GitHub Security Advisories](https://github.com/LouisDM/airgap-coder/security/advisories/new), not a public issue.

## Verified scope

| Layer | Repository verification | What it does not prove |
|---|---|---|
| Management CLI | Syntax, metadata, version, config, and secret-invariant tests | A specific organization's deployment policy |
| Protocol bridge | GPU-free Responses → Chat Completions → function-call integration test | Real-model tool quality or multi-turn reliability |
| Container | Pinned base image, startup, argument routing, and Docker CI | Compatibility with every host runtime |
| Release | Reproducible source archives, checksums, and build provenance | Approval to import artifacts into an isolated network |

The maintained baseline and real-backend reporting rules live in the [compatibility policy](docs/compatibility.md). airgap-coder is an early-stage community project; use the latest [release](https://github.com/LouisDM/airgap-coder/releases/latest) rather than assuming `main` is stable.

## Documentation

| Topic | Guide |
|---|---|
| Installation and concepts | [Documentation index](docs/README.md) |
| Components and data flow | [Architecture](docs/architecture.md) |
| Transfer into an isolated network | [Offline deployment](docs/offline-deployment.md) |
| Common failures | [Troubleshooting](docs/troubleshooting.md) |
| Tested versions and reporting | [Compatibility](docs/compatibility.md) |
| Secrets and trust boundaries | [Threat model](docs/threat-model.md) |
| Local review without an API key | [Codex workflow](docs/codex-workflow.md) |
| Release history | [Changelog](CHANGELOG.md) |

## Community

- Ask setup questions and share deployment patterns in [Discussions](https://github.com/LouisDM/airgap-coder/discussions).
- Open reproducible bugs and feature requests through the [issue templates](https://github.com/LouisDM/airgap-coder/issues/new/choose).
- Read [CONTRIBUTING.md](CONTRIBUTING.md) before submitting code or documentation.
- Add an opt-in, publicly verifiable deployment to the [adopters list](docs/adopters.md).
- Interested in long-term maintenance? See the [maintainer invitation](https://github.com/LouisDM/airgap-coder/issues/18).

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
