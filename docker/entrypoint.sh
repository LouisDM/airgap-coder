#!/usr/bin/env bash
# 容器启动时按环境变量生成 Codex 配置，镜像本身不烤死任何站点信息。
set -euo pipefail

# 不碰模型的子命令先放行，再校验网关配置（issue #29）。
# 搬完镜像的第一个动作往往是核对「这个 tar 里到底是哪个 Codex 版本」——比对
# MANIFEST 里写的版本号，或者排查故障时确认容器内版本。那时候网关可能还没起、
# 地址也可能在另一个团队手上。要求先配网关才能查版本，等于在最需要快速确认
# 的时刻加了一道无关的门槛。Dockerfile 的 `CMD ["--help"]` 也走这条路：
# 不带参数的 `docker run airgap-coder:<ver>` 本该打印用法，而不是要求配网关。
#
# 不放行「无参数」：那是交互式 TUI，它真的要连网关，也要下面生成的 config.toml。
case "${1:-}" in
  --version|-V|--help|-h)
    exec codex "$@"
    ;;
esac

: "${GATEWAY_URL:?必须设置 GATEWAY_URL，例: http://gateway.your-intranet:4000/v1}"
: "${GATEWAY_KEY:?必须设置 GATEWAY_KEY（LiteLLM 的 master key）}"
: "${MODEL:?必须设置 MODEL（网关里注册的 model_name）}"

export LITELLM_MASTER_KEY="$GATEWAY_KEY"

cat > "${CODEX_HOME}/config.toml" <<EOF
model = "${MODEL}"
model_provider = "gateway"

approval_policy = "never"
sandbox_mode = "danger-full-access"

model_context_window = ${CONTEXT_WINDOW}
model_max_output_tokens = ${MAX_OUTPUT_TOKENS}
include_apply_patch_tool = true
model_supports_reasoning_summaries = false

[model_providers.gateway]
name = "LiteLLM Gateway"
base_url = "${GATEWAY_URL}"
env_key = "LITELLM_MASTER_KEY"
wire_api = "responses"
EOF

# `--skip-git-repo-check` 是 `codex exec` 的子命令参数，不能放在 Codex 顶层。
# 容器本身是这里选定的隔离边界；Codex 的 Landlock/seccomp 沙箱在多数容器
# 运行时下会初始化失败，所以仅对非交互 exec 显式关闭。
if [ "${1:-}" = "exec" ]; then
  shift
  exec codex exec \
    --skip-git-repo-check \
    --dangerously-bypass-approvals-and-sandbox \
    "$@"
fi

# --help / --version 等普通 Codex 命令不接受 exec 专属参数。
exec codex "$@"
