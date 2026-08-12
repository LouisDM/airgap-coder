# 隔离网开发容器：Codex CLI + 你的代码，所有模型请求走内网网关。
#
# 构建（在有外网的机器上做一次，产物导出带进内网）：
#   docker build -t airgap-coder:0.1.0 -f docker/Dockerfile .
#   docker pull ghcr.io/berriai/litellm:main-stable@sha256:90d8de0ea6fbb3cad145d1019d00a0149ae400b1e18e2011a60f1988f143f672
#   ./bin/lc export      # 两个镜像 + 源码 + install.sh + MANIFEST 打成一个包
#
# 内网使用（解包后跑 ./install.sh 会自动 docker load）。挂的是你要它改的那个
# 项目目录，不是 airgap-coder / 离线包目录——那里有 lc init 写的 .env，而下面
# entrypoint 里 Codex 是 danger-full-access（issue #50）：
#   docker run -it --rm -v "/path/to/your-project:/workspace" \
#     -e GATEWAY_URL=http://gateway.your-intranet:4000/v1 \
#     -e GATEWAY_KEY=xxx \
#     -e MODEL=your-model-name \
#     airgap-coder:0.1.0 exec "重构 foo.py"

# 基础镜像跟 Node 的 Active LTS，不跟 Current。这个镜像构建一次就 docker save
# 搬进内网，之后没有更新路径——内网里发现问题没法 pull 补救。所以稳定性和长期
# 安全支持优先于新特性，和下面锁死 CODEX_VERSION 是同一个理由。
# 用 digest 固定：node:24-slim 这个 tag 会随小版本移动，两次构建可能拿到不同镜像。
FROM node:24-slim@sha256:3638d9a6fe4030bd716be989438248074489337ba3275657f93595428be4fc03

# 版本锁死。Codex 有过单方面移除 wire_api="chat" 的先例，
# 隔离网环境不应该留自动更新的口子。
ARG CODEX_VERSION=0.145.0

# 镜像 tag 用的是本项目的版本（VERSION），不是 Codex 的——airgap-coder 自己迭代
# 而不换 Codex 版本是常态，用 Codex 版本会让不同发布产生同名镜像（issue #36）。
# 所以 tag 里看不到 Codex 版本了，用 label 记下来：内网侧 `docker inspect` 就能
# 问出「这个镜像锁的是哪个 Codex」，不必翻 MANIFEST。
# APP_VERSION 必须和 VERSION 文件一致，scripts/test-version.sh 钉住这一点。
ARG APP_VERSION=0.1.0
LABEL org.opencontainers.image.title="airgap-coder" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.source="https://github.com/LouisDM/airgap-coder" \
      org.opencontainers.image.description="Codex CLI for air-gapped networks" \
      io.airgap-coder.codex-version="${CODEX_VERSION}"

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
