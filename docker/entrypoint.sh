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

# 工作区里躺着 .env 时提醒，但**不阻断**（issue #50）。
#
# 上面 `sandbox_mode = "danger-full-access"` 的前提是「挂进来的只有该看的工作区」，
# 而文档一度教的是 `-v "$PWD:/workspace"`，紧跟在 `lc init` 把凭证写进那个目录的
# .env 之后——顺着文档走必然把它挂进来。容器里只注入了 LITELLM_MASTER_KEY
# （issue #42 收紧的那条），但挂载把整份 .env 又送了回来：里面是**全部**上游的
# 地址、API Key 和自定义头的值，包括这次会话用不到的。
#
# 这条检查只能长在这里：`lc code` 那句同样的警告在 bin/lc 里，容器路径根本不跑
# lc，结构上不可能触发。判据用 $PWD 而不是写死 /workspace，这样 `-w` 换过工作
# 目录也照样成立；只报路径，不读文件、不打印任何值。
#
# 不阻断的理由同 bin/lc 的 warn_env_in_workspace()：在这个目录里用 Codex 审查
# airgap-coder 自己是正当用法，拒绝会挡住它，而放行 flag 加上去之后就永远带着。
if [ -f "${PWD}/.env" ]; then
  {
    echo "⚠️  工作区里有 .env：${PWD}/.env"
    echo "   这个会话是 approval_policy = \"never\" + sandbox_mode = \"danger-full-access\"："
    echo "   模型发的 shell 命令不用批准直接执行，一句 \`cat .env\` 就能读走里面全部上游的地址与凭证。"
    echo "   要避开：挂你要它改的那个项目目录，别挂 airgap-coder 或离线包目录——"
    echo "   docker run ... -v \"/path/to/your-project:/workspace\" ..."
  } >&2
fi

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
