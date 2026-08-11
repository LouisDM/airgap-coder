# airgap-coder

Run the OpenAI Codex CLI against self-hosted models in air-gapped or restricted networks.

[简体中文](README.zh-CN.md) | [Contributing](CONTRIBUTING.md) | [Security](SECURITY.md)

airgap-coder provides a zero-dependency `lc` management CLI and a LiteLLM gateway that translate Codex's Responses API traffic into Chat Completions requests understood by vLLM, SGLang, and compatible inference services.

```text
Codex CLI --Responses API--> LiteLLM --Chat Completions--> your model service
 (container)                  (gateway)                    (private GPU network)
```

## Why this exists

Codex 0.145 and later use the Responses API. Many self-hosted inference servers expose only `/v1/chat/completions`. airgap-coder generates the gateway and Codex configuration needed to bridge that gap while keeping endpoint URLs, API keys, and private header values out of version control.

The project is designed for environments where:

- development machines or GPU clusters cannot reach the public internet;
- model credentials must stay in a local `.env` file;
- the same non-secret model registry must be shared by a team;
- images and source must be exported as a verifiable offline bundle;
- tool calling must be tested before Codex is trusted to edit code.

## Quick start

Requirements: Python 3.9+, Docker with Compose, and Codex CLI 0.145.0 for host-side use.

```bash
git clone https://github.com/LouisDM/airgap-coder.git
cd airgap-coder
./bin/lc init
./bin/lc up
./bin/lc test
./bin/lc code
```

`lc init` asks for the upstream URL, API key, model ID, context window, and backend family. Secrets and private endpoints are written only to the ignored `.env`; `registry.json` contains variable names and non-secret structure so it can be reviewed and shared.

## Commands

| Command | Purpose |
|---|---|
| `lc init` | Configure the first upstream interactively |
| `lc add`, `lc rm <n>`, `lc ls` | Manage upstream definitions |
| `lc use <n>` | Select the default upstream |
| `lc up`, `lc down`, `lc status`, `lc logs` | Manage the gateway |
| `lc test [n]` | Run five protocol and tool-calling checks |
| `lc e2e [n]` | Ask Codex to edit a fixture and verify the result |
| `lc code [...]` | Start Codex with the selected upstream |
| `lc doctor` | Diagnose proxy, connectivity, and tool-calling behavior |
| `lc sync` | Regenerate LiteLLM and Codex configuration |
| `lc migrate` | Move legacy plaintext header values into `.env` |
| `lc export [--no-images] [--no-registry]` | Create a checksummed, self-contained offline bundle |

## Security model

airgap-coder deliberately separates shareable configuration from secrets:

- `.env`, generated Codex profiles, and generated LiteLLM config are ignored;
- `registry.json` may be committed but stores only environment-variable names for private values;
- offline export uses `git ls-files`, excludes `.env` and generated configuration, records image digests, and creates `SHA256SUMS`;
- the bundle carries `registry.json` so the isolated side reuses reviewed model structure instead of guessing it; export refuses to run while that file still holds plaintext header values, and `--no-registry` omits it;
- CI exercises the secret-handling invariants without needing a model key.

Read the full [threat model](docs/threat-model.md) before deploying in a sensitive environment. This project does not make an untrusted model, gateway, container runtime, or developer workstation safe by itself.

## Self-hosted backend requirements

The backend model must support reliable function calling. A typical vLLM launch includes:

```bash
--enable-auto-tool-choice --tool-call-parser hermes --max-model-len 131072
```

For Qwen-family models, disabling thinking mode commonly improves tool-call parsing. airgap-coder supports both common parameter shapes:

- vLLM/SGLang: `chat_template_kwargs: {"enable_thinking": false}`
- hosted gateways: top-level `enable_thinking: false`

Run `lc test` and `lc e2e` against your exact model and inference-server version. Compatibility reports are documented in [docs/compatibility.md](docs/compatibility.md).

## Offline export

On a connected staging machine:

```bash
docker build -t airgap-coder:0.145.0 -f docker/Dockerfile .
docker pull ghcr.io/berriai/litellm:main-stable@sha256:90d8de0ea6fbb3cad145d1019d00a0149ae400b1e18e2011a60f1988f143f672
./bin/lc export
```

Move the resulting archive into the isolated network, extract it, and run `./install.sh`. The installer verifies checksums before loading images. `lc init` on the isolated side then reuses the bundled `registry.json` and asks only for that site's endpoint and credential. Use `./bin/lc export --no-images` when only tracked source changed, and `--no-registry` when building one generic bundle for several sites.

## Project status and scope

airgap-coder is an early-stage community project. It currently targets Codex CLI 0.145.0 and validates the configuration bridge without requiring a public OpenAI API key. See the [compatibility policy](docs/compatibility.md), [architecture](docs/architecture.md), and [changelog](CHANGELOG.md).

Adoption is tracked only through opt-in pull requests in [docs/adopters.md](docs/adopters.md); the project has no telemetry. Contributions, reproducible compatibility reports, and documentation improvements are welcome. Maintainers can run [local Codex review](docs/codex-workflow.md) with ChatGPT sign-in and no `OPENAI_API_KEY`.

## License

Apache-2.0. See [LICENSE](LICENSE).
