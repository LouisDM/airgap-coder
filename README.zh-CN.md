<div align="center">

# airgap-coder

**在隔离网或受限网络中，让 Codex CLI 使用自托管模型。**

[English](README.md) · [**简体中文**](README.zh-CN.md)

[![CI](https://github.com/LouisDM/airgap-coder/actions/workflows/ci.yml/badge.svg)](https://github.com/LouisDM/airgap-coder/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/LouisDM/airgap-coder?display_name=tag)](https://github.com/LouisDM/airgap-coder/releases/latest)
[![License](https://img.shields.io/github/license/LouisDM/airgap-coder)](LICENSE)

[快速开始](#快速开始) · [文档](docs/README.md) · [兼容性](docs/compatibility.md) · [讨论区](https://github.com/LouisDM/airgap-coder/discussions)

</div>

airgap-coder 通过固定版本的 LiteLLM 网关，把 OpenAI Codex CLI 接到 vLLM、SGLang 等自托管 Chat Completions 服务。零第三方依赖的 `lc` 管理命令负责生成配置、隔离私密值、验证工具调用，并生成带校验和的离线部署包。

```text
Codex CLI --Responses API--> LiteLLM --Chat Completions--> 自托管模型
 主机或容器                    协议网关                    内网 GPU 服务
```

> [!IMPORTANT]
> airgap-coder 不包含模型或推理服务。你的模型、chat template、tool parser、推理服务版本和 Codex 版本必须一起通过 `lc doctor`、`lc test` 与 `lc e2e`。

## 为什么需要 airgap-coder

新版 Codex 使用 Responses API，而许多自托管推理服务只提供 Chat Completions。HTTP 请求成功并不代表编码代理可用：它还依赖可靠的 function calling、正确的上下文窗口，以及多台机器之间一致的配置。

airgap-coder 提供：

- **协议翻译**：以镜像 digest 固定版本的 LiteLLM 网关将 Responses 请求转换为 Chat Completions 请求。
- **机密隔离**：地址、API Key 和私有 HTTP 头值只保存在被忽略且权限为 `0600` 的 `.env` 中。
- **团队配置**：`registry.json` 只保存模型结构和环境变量名，不保存解析后的私密值。
- **行为诊断**：`lc doctor`、`lc test`、`lc e2e` 能区分“网络可达”和“工具调用真正可用”。
- **离线交付**：`lc export` 将已跟踪源码、容器镜像、清单和校验和打成可审核的离线包。
- **确定性验证**：CI 不需要 GPU、真实模型或 OpenAI API Key，也能验证机密不变量和协议桥接。

## 快速开始

### 在主机运行 Codex

要求：Python 3.9+、带 Compose 插件的 Docker，以及 Codex CLI `0.145.0`。

```bash
git clone https://github.com/LouisDM/airgap-coder.git
cd airgap-coder
npm install -g @openai/codex@0.145.0

./bin/lc init    # 配置自托管上游
./bin/lc up      # 启动 LiteLLM 网关
./bin/lc test    # 验证协议和工具调用
./bin/lc code    # 使用当前上游启动 Codex
```

`lc init` 会询问上游地址、凭证、模型 ID、上下文窗口和后端类型。解析后的地址与凭证只写入 `.env`；可共享的结构写入 `registry.json`。

这条路径**不需要** `OPENAI_API_KEY`，使用的是你的自托管模型凭证。维护者也可以通过现有 ChatGPT 登录态执行[只读的本地 Codex 审查](docs/codex-workflow.md)。

### 在隔离容器中运行 Codex

先在有网络的中转机上构建固定版本镜像，通过获批流程转移到内网，再连接内网网关：

```bash
docker run --rm -it -v "$PWD:/workspace" \
  -e GATEWAY_URL=http://gateway.your-intranet.local:4000/v1 \
  -e GATEWAY_KEY=your-gateway-key \
  -e MODEL=your-model \
  airgap-coder:0.145.0 exec "检查这个仓库"
```

跨越网络边界前，请先阅读完整的[离线部署指南](docs/offline-deployment.md)。

## 工作原理

1. `lc init` 或 `lc add` 将私密值写入 `.env`，将非机密模型结构写入 `registry.json`。
2. `lc sync` 根据这两个数据源生成被 Git 忽略的 LiteLLM 与 Codex 配置。
3. LiteLLM 接收 Codex 的 `/v1/responses` 请求，并向所选上游发送 `/v1/chat/completions` 请求。
4. `lc test` 检查协议桥接和工具调用结构；`lc e2e` 验证 Codex 能否完成受控的代码修改。
5. `lc export` 为隔离环境生成自包含部署包。

组件和信任边界详见[架构文档](docs/architecture.md)。

## 命令参考

| 命令 | 作用 |
|---|---|
| `lc init` | 交互式配置第一个上游 |
| `lc add`、`lc rm <name>`、`lc ls` | 管理上游定义 |
| `lc use <name>` | 切换默认上游 |
| `lc up`、`lc down`、`lc status`、`lc logs` | 管理网关生命周期 |
| `lc test [name]` | 执行协议与工具调用检查 |
| `lc e2e [name]` | 让 Codex 修改测试文件并验证结果 |
| `lc code [...]` | 使用所选上游启动主机上的 Codex |
| `lc doctor` | 诊断版本、代理、连接与工具调用 |
| `lc sync` | 重新生成 LiteLLM 与 Codex 配置 |
| `lc migrate` | 将旧版明文 HTTP 头值迁移到 `.env` |
| `lc export [--no-images]` | 生成带校验和的离线部署包 |
| `lc version` | 显示 airgap-coder 与固定的 Codex 版本 |

运行 `./bin/lc help` 可查看内置说明。

## 后端要求

上游必须提供兼容 OpenAI 的 Chat Completions 端点，并能返回结构正确的 function call。典型的 vLLM 启动参数包括：

```bash
--enable-auto-tool-choice --tool-call-parser hermes --max-model-len 131072
```

对 Qwen 系列模型，关闭思考模式通常有助于工具调用解析。airgap-coder 支持两种常见参数结构：

- vLLM/SGLang：`chat_template_kwargs: {"enable_thinking": false}`
- 托管网关：顶层 `enable_thinking: false`

这些只是起点，不代表对所有版本作兼容承诺。请验证你的完整部署，并通过[兼容性报告](https://github.com/LouisDM/airgap-coder/issues/new?template=compatibility.yml)提交可复现结果。

## 安全边界

- `.env`、生成的 Codex profile 和生成的 LiteLLM 配置都被 Git 忽略。
- 离线导出只包含已跟踪源码，并排除 `.env`、`registry.json`、生成配置、Git 历史和本地 Codex 状态。
- Release 源码包包含 SHA-256 校验和与 GitHub 构建来源证明。
- airgap-coder 本身不采集遥测，但模型服务、网关、容器运行时和 Codex 运行时是独立信任边界，可能各自记录日志。
- 校验和能证明文件完整性，但不代表其中内容已获准进入特定隔离环境。

请阅读完整的[威胁模型](docs/threat-model.md)和[安全政策](SECURITY.md)。漏洞必须通过 [GitHub Security Advisories](https://github.com/LouisDM/airgap-coder/security/advisories/new) 私下报告，不要公开提 issue。

## 已验证范围

| 层级 | 仓库中的验证 | 不能证明什么 |
|---|---|---|
| 管理 CLI | 语法、元数据、版本、配置和机密不变量测试 | 某个组织的具体部署政策 |
| 协议桥接 | 无 GPU 的 Responses → Chat Completions → function-call 集成测试 | 真实模型的工具质量或多轮稳定性 |
| 容器 | 固定基础镜像、启动、参数路由和 Docker CI | 与所有宿主运行时兼容 |
| Release | 可复现源码包、校验和与构建来源证明 | 产物已获准进入隔离网络 |

维护基线与真实后端报告规则见[兼容性政策](docs/compatibility.md)。airgap-coder 仍是早期社区项目；请优先使用最新 [Release](https://github.com/LouisDM/airgap-coder/releases/latest)，不要默认 `main` 始终稳定。

## 文档

| 主题 | 指南 |
|---|---|
| 安装与概念 | [文档索引](docs/README.md) |
| 组件与数据流 | [架构](docs/architecture.md) |
| 搬运到隔离网络 | [离线部署](docs/offline-deployment.md) |
| 常见故障 | [故障排查](docs/troubleshooting.md) |
| 已测版本与报告方式 | [兼容性](docs/compatibility.md) |
| 机密与信任边界 | [威胁模型](docs/threat-model.md) |
| 无 API Key 的本地审查 | [Codex 工作流](docs/codex-workflow.md) |
| 版本记录 | [Changelog](CHANGELOG.md) |

## 社区

- 在 [Discussions](https://github.com/LouisDM/airgap-coder/discussions) 提问或交流部署模式。
- 通过 [issue 模板](https://github.com/LouisDM/airgap-coder/issues/new/choose)提交可复现缺陷和功能建议。
- 提交代码或文档前阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。
- 通过 PR 将公开、可验证的部署加入[采用者列表](docs/adopters.md)。
- 有意长期参与维护？请查看[中文维护者招募](https://github.com/LouisDM/airgap-coder/issues/17)。

## 许可证

Apache-2.0，详见 [LICENSE](LICENSE) 与 [NOTICE](NOTICE)。
