# Troubleshooting

Start with the built-in checks and keep their redacted output when asking for help:

```bash
./bin/lc doctor
./bin/lc status
./bin/lc test
```

Never share `.env`, private endpoints, credentials, prompts, proprietary source, or generated configuration containing resolved values.

## Gateway does not start

Check container state and logs:

```bash
./bin/lc status
./bin/lc logs
```

Run `./bin/lc sync` to regenerate configuration from `registry.json` and `.env`, then restart with `./bin/lc down && ./bin/lc up`. If `.env` is incomplete, run `./bin/lc init` again.

## Upstream returns 404 or `Unsupported model`

Confirm that the configured base URL ends at `/v1` and that the model ID matches the upstream exactly. Regenerate the gateway configuration with `./bin/lc sync`.

airgap-coder's generated LiteLLM model entry uses `use_chat_completions_api: true`. Without that bridge setting, a Responses request may be forwarded to an upstream that only implements Chat Completions.

## Chat works but tool calls are empty

Connectivity alone is not sufficient for Codex. Run `./bin/lc doctor`; its direct upstream probe sends a tool definition and checks for a structurally valid function call.

For vLLM, a typical starting point is:

```bash
--enable-auto-tool-choice --tool-call-parser hermes --max-model-len 131072
```

Select the parser and chat template for the exact model and inference-server version. Then rerun both `lc test` and `lc e2e`.

## Thinking text interferes with tool calls

For model families that expose a thinking mode, try the parameter shape supported by the upstream:

- vLLM/SGLang: `chat_template_kwargs.enable_thinking=false`
- hosted gateways: top-level `enable_thinking=false`

Run `lc init` or `lc add` and select the correct backend family instead of editing generated configuration by hand.

## The host cannot reach an internal address

`lc doctor` reports common proxy environment variables. If an HTTP proxy or tunnel captures internal DNS or traffic, configure an appropriate `NO_PROXY` value or bypass rule for the approved internal hostname. Do not disable an organization-mandated proxy without authorization.

## Host and container behave differently

Run `./bin/lc doctor` to compare the host Codex version with the version pinned in `docker/Dockerfile`. Align the versions before diagnosing model behavior; protocol and configuration support can change across Codex releases.

Also compare:

- the exact LiteLLM image digest;
- model ID and context window;
- tool parser and chat template;
- generated parameter shape;
- proxy environment and network path.

## Codex reports missing model metadata

A self-hosted model may not exist in Codex's built-in model catalog. Treat the message as a warning only after confirming that the generated profile has the intended model and context limits and that `lc test` and `lc e2e` pass.

## Ask for help

Use [GitHub Discussions](https://github.com/LouisDM/airgap-coder/discussions) for setup questions. Use a [compatibility report](https://github.com/LouisDM/airgap-coder/issues/new?template=compatibility.yml) for a reproducible backend result and the bug template for behavior that is broken in airgap-coder itself.
