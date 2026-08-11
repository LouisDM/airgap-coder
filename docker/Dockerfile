# 隔离网开发容器：Codex CLI + 你的代码，所有模型请求走内网网关。
#
# 构建（在有外网的机器上做一次，产物导出带进内网）：
#   docker build -t airgap-coder:0.145.0 -f docker/Dockerfile .
#   docker pull ghcr.io/berriai/litellm:main-stable@sha256:90d8de0ea6fbb3cad145d1019d00a0149ae400b1e18e2011a60f1988f143f672
#   ./bin/lc export      # 两个镜像 + 源码 + install.sh + MANIFEST 打成一个包
#
# 内网使用（解包后跑 ./install.sh 会自动 docker load）：
#   docker run -it --rm -v "$PWD:/workspace" \
#     -e GATEWAY_URL=http://gateway.your-intranet:4000/v1 \
#     -e GATEWAY_KEY=xxx \
#     -e MODEL=your-model-name \
#     airgap-coder:0.145.0 exec "重构 foo.py"

FROM node:26-slim@sha256:4ebb5ace66f15a24c14c492e01a8beeed4fddf970a856109f5126e703e5fe503

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
