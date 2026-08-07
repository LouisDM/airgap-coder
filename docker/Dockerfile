# 隔离网开发容器：Codex CLI + 你的代码，所有模型请求走内网网关。
#
# 构建（在有外网的机器上做一次，产物导出带进内网）：
#   docker build -t airgap-coder:0.145.0 -f docker/Dockerfile .
#   docker save airgap-coder:0.145.0 | gzip > airgap-coder.tar.gz
#   docker pull ghcr.io/berriai/litellm:main-stable
#   docker save ghcr.io/berriai/litellm:main-stable | gzip > litellm.tar.gz
#
# 内网使用：
#   docker load < airgap-coder.tar.gz
#   docker run -it --rm -v "$PWD:/workspace" \
#     -e GATEWAY_URL=http://gateway.your-intranet:4000/v1 \
#     -e GATEWAY_KEY=xxx \
#     -e MODEL=your-model-name \
#     airgap-coder:0.145.0 exec "重构 foo.py"

FROM node:22-slim

# 版本锁死。Codex 有过单方面移除 wire_api="chat" 的先例，
# 隔离网环境不应该留自动更新的口子。
ARG CODEX_VERSION=0.145.0
RUN npm i -g "@openai/codex@${CODEX_VERSION}" \
 && npm cache clean --force \
 && rm -rf /root/.npm /tmp/*

ENV CODEX_HOME=/etc/codex
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh && mkdir -p "$CODEX_HOME"

# 关掉一切外网自更新行为（离线环境下只会拖慢启动并刷错误日志）
ENV CODEX_DISABLE_UPDATE_CHECK=1 \
    NO_UPDATE_NOTIFIER=1 \
    npm_config_update_notifier=false \
    CONTEXT_WINDOW=131072 \
    MAX_OUTPUT_TOKENS=16384

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["--help"]
