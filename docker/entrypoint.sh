#!/usr/bin/env bash
# 容器启动时按环境变量生成 Codex 配置，镜像本身不烤死任何站点信息。
set -euo pipefail

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

# 容器本身就是隔离边界；Codex 的 Landlock/seccomp 沙箱在多数容器运行时下
# 会初始化失败，显式关掉避免启动即报错。
exec codex \
  --skip-git-repo-check \
  --dangerously-bypass-approvals-and-sandbox \
  "$@"
