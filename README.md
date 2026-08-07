# airgap-coder

在**没有外网的内网环境**里跑 AI 编码 CLI。以 Codex CLI 为底座，通过 LiteLLM 网关
接任何 OpenAI 协议兼容的模型服务（vLLM / SGLang / 自建推理网关都行）。

配置全部通过 `lc` 命令完成，不需要手改 yaml/toml。

```
Codex CLI ──Responses协议──> LiteLLM 网关 ──ChatCompletions──> 你的模型服务
 (容器内)                     (内网常驻)                        (内网 GPU 机)
```

## 快速开始

```bash
git clone git@github.com:LouisDM/airgap-coder.git && cd airgap-coder
npm i -g @openai/codex@0.145.0      # 底座
./bin/lc init                        # 交互式配置：填地址、key、模型名
./bin/lc up                          # 起网关
./bin/lc test                        # 协议层 5 项体检
./bin/lc code                        # 开始用
```

`lc init` 会问你上游地址、API Key、模型 ID、上下文大小，以及后端类型（决定
关闭思考模式该用哪个参数名）。密钥只写进 `.env`（已 gitignore）。

## 命令

| 命令 | 作用 |
|---|---|
| `lc init` | 交互式初始化 |
| `lc add` / `rm <n>` / `ls` | 增删查上游 |
| `lc use <n>` | 切换默认上游 |
| `lc up` / `down` / `status` / `logs` | 网关生命周期 |
| `lc test [n]` | 协议层 5 项（含 tool calling 与 Responses 桥接） |
| `lc e2e [n]` | 端到端：让 Codex 真改代码并校验结果 |
| `lc code [...]` | 用当前上游启动 Codex |
| `lc doctor` | 环境体检，含代理劫持检测 |
| `lc sync` | 由 registry.json 重新生成配置 |

## 为什么需要 LiteLLM 网关

不是可选项。Codex 从 **0.145 起移除了 `wire_api = "chat"`**，只支持 OpenAI 的
Responses 协议（[讨论](https://github.com/openai/codex/discussions/7782)），
而 vLLM / SGLang 只提供 `/v1/chat/completions`。网关负责这层翻译，顺带解决
密钥统一下发吊销、请求日志留痕、模型名映射、换上游对 CLI 透明。

关键开关是 `use_chat_completions_api: true`。不加它，LiteLLM 会把 `/v1/responses`
原样透传给上游，上游没这个端点，直接 404 / Unsupported model。`lc` 生成的配置
默认带上。

## 上线内网

1. 有外网的机器上导出两个镜像：
   ```bash
   docker build -t airgap-coder:0.145.0 -f docker/Dockerfile .
   docker save airgap-coder:0.145.0 | gzip > airgap-coder.tar.gz
   docker pull ghcr.io/berriai/litellm:main-stable
   docker save ghcr.io/berriai/litellm:main-stable | gzip > litellm.tar.gz
   ```
2. 内网起网关：`lc init` 填内网地址 → `lc up`
3. 开发机跑容器：
   ```bash
   docker run -it --rm -v "$PWD:/workspace" \
     -e GATEWAY_URL=http://gateway.your-intranet:4000/v1 \
     -e GATEWAY_KEY=xxx -e MODEL=your-model \
     airgap-coder:0.145.0 exec "重构 foo.py"
   ```
   镜像不烤死任何站点信息，配置在 entrypoint 里按环境变量生成。

## 后端要求

模型服务必须支持 **function calling**，否则 Codex 无法读写文件。vLLM 需要：

```bash
--enable-auto-tool-choice --tool-call-parser hermes --max-model-len 131072
```

`--max-model-len` 要和 `lc` 里填的 context window 一致。parser 按模型family 选
（Qwen 系用 `hermes`，以你的 vLLM 版本文档为准）。

**建议关闭思考模式**。Qwen3 等模型的 `<think>` 块会干扰 tool call 解析。参数名
两家不同，`lc init` 会问你：

- vLLM / SGLang：`chat_template_kwargs: {"enable_thinking": false}`
- 托管服务（百炼等）：顶层 `enable_thinking: false`

## 选型：为什么是 Codex

| | Codex CLI | OpenCode | Claude Code |
|---|---|---|---|
| 协议 | Responses（需网关翻译） | 原生 chat/completions | Anthropic Messages |
| 开源 | Apache-2.0 | MIT | 闭源 |
| 运行时 | Rust 单二进制 | Node/Bun | Node |
| 离线 | 好，无启动期外网请求 | 中，启动拉 models.dev、provider 按需装 npm | 差，需关一堆遥测 |

Codex 胜在单二进制、可审计、无运行时外网依赖。代价是必须挂网关翻译协议——
但网关本来就要有。**如果你的模型 tool calling 不达标**（`lc test` 第 3、5 步不过），
退到 OpenCode（原生说 chat/completions）或 Aider（纯文本 diff，完全不依赖 tool calling）。

## 实测记录

用 `qwen3-32b`（阿里云百炼托管版，作为内网同规格代理）验证：

| 配置 | 端到端通过率 |
|---|---|
| 默认 | 3/5 —— 偶发漏 import、误用 shell heredoc 转义 |
| 开 `include_apply_patch_tool` | 3/3 |

`unsupported call: apply_patch` 是关键线索：不注册该工具时，模型会退化成用
shell heredoc 写文件，转义容易出错。开启后稳定性明显改善。样本量小，仅供参考。

同规格对比中 `qwen3-coder-flash`（= Qwen3-Coder-30B-A3B-Instruct，MoE）表现更稳，
显存占用与 32B dense 接近，**内网部署建议优先考虑它而非 Qwen3-32B**。

## 已知问题

- **Codex 会警告 `Model metadata for X not found`**。纯提示性，来自 Codex 内置
  模型注册表，设 `model_context_window` 也消不掉，不影响功能。
- **profile 名写错不报错**。Codex 对不存在的 profile 静默回落到默认 model，会
  出现"以为在测 A 其实在测 B"。`lc` 生成的脚本已加防呆。
- **Kimi 走 Codex 多轮会挂**（`tool_call_ids did not have response messages`）。
  已排除 tool_call_id 格式与桥接的多轮转换问题，疑似 reasoning 模型的 reasoning
  item 回传，未根因定位。不影响 vLLM 类后端。
- **本机有代理时连不上内网地址**。Clash 等 tun 模式会劫持 DNS，`lc doctor` 会检测
  并提示；给内网域名加 DIRECT 规则即可。

## 结构

| 路径 | 说明 |
|---|---|
| `bin/lc` | 配置与运维 CLI（无第三方依赖） |
| `registry.json` | 上游注册表，**gitignore**；模板见 `registry.example.json` |
| `.env` | 密钥，**gitignore** |
| `litellm/config.yaml`、`codex/*.toml` | 由 `lc sync` 生成，**gitignore** |
| `docker/` | 隔离网开发镜像 |
| `scripts/smoke.py` | 协议层 5 项测试 |
| `scripts/test-codex.sh` | 端到端测试 |
