# Architecture

airgap-coder is a configuration and packaging layer. It does not host a model and it does not replace the Codex CLI.

```text
Developer workstation
  └─ Codex CLI (Responses API)
       └─ LiteLLM gateway (protocol and model-name translation)
            └─ vLLM, SGLang, or compatible Chat Completions service
```

## Components

| Component | Responsibility | Trust boundary |
|---|---|---|
| `bin/lc` | Manage upstreams, generate config, operate the gateway, run checks, export bundles | Runs on the developer or staging host |
| `registry.json` | Share model IDs, context limits, parameter shape, and environment-variable names | Safe to commit only while it contains no resolved private values |
| `.env` | Store endpoint URLs, API keys, and private header values | Local secret; never commit or export |
| LiteLLM | Accept Responses requests and issue Chat Completions requests | Handles prompts, outputs, tools, and upstream credentials |
| Codex container | Run the pinned Codex CLI against the configured gateway | Can read and modify the mounted workspace according to Codex sandbox settings |
| Offline bundle | Carry tracked source and pre-pulled images across the network boundary | Must be checksummed and transferred through an approved process |

## Configuration flow

1. `lc init`, `lc add`, or `lc migrate` write secret values to `.env` and non-secret structure to `registry.json`.
2. `lc sync` resolves those inputs into ignored `litellm/config.yaml` and `codex/*.config.toml` files.
3. `lc up` starts LiteLLM with the generated gateway configuration.
4. `lc code` starts Codex with the selected generated profile.
5. `lc test`, `lc e2e`, and `lc doctor` validate increasingly complete paths.

Generated files are disposable. `registry.json` and `.env` are the sources of truth, separated so teams can review structural changes without publishing credentials.

## Protocol bridge

Codex sends Responses API requests. The generated LiteLLM model entry sets `use_chat_completions_api: true`, causing LiteLLM to translate them before reaching an upstream that exposes `/v1/chat/completions`. The bridge is useful only when the upstream model and server implement tool calling correctly; HTTP success alone is not sufficient.

## Offline release flow

The staging host builds or pulls the required images, then `lc export` packages tracked source, image archives, an installer, a manifest, image digests, and checksums. It intentionally excludes local secrets and generated state. The isolated host verifies checksums before loading images.
