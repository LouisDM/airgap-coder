#!/usr/bin/env bash
# 钉住 lc use / ls / up / down / status 的行为（issue #12 第二梯队）。
#
# 这五个命令写坏了不会泄密，但会浪费大量排查时间，而且其中两条正好踩在项目
# 已知的坑上：
#   - `lc use` 切完之后 codex/config.toml 的默认 model 必须真的变。Codex 对
#     不存在的 profile 是**静默回落**到默认 model 的，切换没生效不会有任何报错，
#     表现成「以为在测 A，其实在测 B」。
#   - `lc status` 在网关不可达时要给一句干净的话，不是 Python traceback。
#
# 跑 docker 的那三条用一个假 docker 桩（记录 argv 到文件），断言的是「参数拼装
# 对不对」；网关侧用一个真的 HTTP 桩，让 wait_gw 立刻成功——不然 lc up 会老老实实
# 等满 45 秒。
#
# 用法: bash scripts/test-lc-commands.sh    （零依赖，只用 Python 标准库）
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# lc 的 ROOT 由自身路径推导，所以复制到临时目录后它读写的 registry.json /
# .env / litellm/ / codex/ 全落在那里，不碰开发机上真实的配置。
WORK="$(mktemp -d)"
GW_PID=""
cleanup() {
  [ -n "$GW_PID" ] && kill "$GW_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

SRC="$WORK/repo"
mkdir -p "$SRC/bin" "$WORK/bin"
cp "$REPO/bin/lc" "$SRC/bin/lc"
LC=("python3" "$SRC/bin/lc")
REG="$SRC/registry.json"
ENVF="$SRC/.env"

# 哨兵值运行时现生成：这个脚本自己也是仓库源码，写死的字面量会让「按值搜」的
# 断言被脚本自身内容误触发（test-export.sh 踩过这个坑）。
CANARY_KEY="lc-cmd-key-canary-$$-${RANDOM}${RANDOM}"
CANARY_HDR="lc-cmd-hdr-canary-$$-${RANDOM}${RANDOM}"
CANARY_MK="lc-cmd-mk-canary-$$-${RANDOM}${RANDOM}"

fails=0
pass() { echo "  ✅ $1"; }
fail() { echo "  ❌ $1"; echo "::error::$1"; fails=$((fails + 1)); }

have()   { grep -qF -e "$2" "$1"; }          # have <文件> <字符串>
assert() { if have "$2" "$3"; then pass "$1"; else fail "$1"; fi; }
refute() { if have "$2" "$3"; then fail "$1"; else pass "$1"; fi; }

# 空闲端口现取：CI 上并发跑别的东西时写死端口会偶发冲突，而那种红看起来
# 像是产品缺陷。
PORT="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"

python3 - "$REG" "$PORT" <<'PY'
import json, sys
json.dump({
    "default": "alpha",
    "gateway_port": int(sys.argv[2]),
    "upstreams": {
        "alpha": {"model": "Qwen/Qwen3-32B", "env_key": "KEY_ALPHA",
                  "env_base": "KEY_ALPHA_BASE", "context_window": 131072,
                  "max_output_tokens": 16384,
                  "params": {"chat_template_kwargs": {"enable_thinking": False}},
                  "headers": {"User-Agent": "KEY_ALPHA_HEADER_USER_AGENT"}},
        "beta": {"model": "Qwen/Qwen3-8B", "env_key": "KEY_BETA",
                 "env_base": "KEY_BETA_BASE", "context_window": 32768,
                 "max_output_tokens": 8192, "params": {}, "headers": {}},
    },
}, open(sys.argv[1], "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY

cat > "$ENVF" <<EOF
LITELLM_MASTER_KEY=sk-$CANARY_MK
KEY_ALPHA=$CANARY_KEY
KEY_ALPHA_BASE=http://alpha.your-intranet.local:8000/v1
KEY_ALPHA_HEADER_USER_AGENT=$CANARY_HDR
KEY_BETA=${CANARY_KEY}-beta
KEY_BETA_BASE=http://beta.your-intranet.local:8000/v1
EOF

run() {  # run <日志> <lc 参数...>；命令必须成功
  local log="$1"; shift
  if ! NO_COLOR=1 PATH="$WORK/bin:$PATH" "${LC[@]}" "$@" < /dev/null > "$log" 2>&1; then
    cat "$log"
    echo "::error::lc $* 执行失败"
    exit 1
  fi
}

run_any() {  # run_any <日志> <lc 参数...>；不管退出码，只看输出
  local log="$1"; shift
  NO_COLOR=1 PATH="$WORK/bin:$PATH" "${LC[@]}" "$@" < /dev/null > "$log" 2>&1 || true
}

run_fail() {  # run_fail <日志> <lc 参数...>；命令必须失败
  local log="$1"; shift
  if NO_COLOR=1 PATH="$WORK/bin:$PATH" "${LC[@]}" "$@" < /dev/null > "$log" 2>&1; then
    cat "$log"
    fail "lc $* 应当以非零退出码失败，实际成功了"
    return 1
  fi
  # 报错要是给人看的一句话，不是 Python traceback
  refute "lc $*：失败时没有吐 traceback" "$log" "Traceback (most recent call last)"
}

# ─────────────────────────────────────────────────────────────────────────
echo "[1] lc use：切换默认上游，且生成的 Codex 配置真的跟着变"
# Codex 对不存在的 profile 静默回落到默认 model，所以「切了但没生效」不会报错，
# 只会表现成结果不对。这里连 codex/config.toml 一起断言，不只看 registry。
run "$WORK/log-sync" sync
CFG_TOML="$SRC/codex/config.toml"
assert "切换前默认 model 是 alpha" "$CFG_TOML" 'model = "alpha"'

run "$WORK/log-use" use beta
assert "use 有明确的成功回执"        "$WORK/log-use" "默认上游已切换为 beta"
assert "registry 的 default 变了"    "$REG" '"default": "beta"'
assert "codex/config.toml 的默认 model 跟着变了" "$CFG_TOML" 'model = "beta"'
refute "codex/config.toml 里不再指向旧的默认上游" "$CFG_TOML" 'model = "alpha"'
# profile 文件是每个上游各一份，切默认不该把别人的删掉
test -f "$SRC/codex/alpha.config.toml" && test -f "$SRC/codex/beta.config.toml" \
  && pass "两个上游的 profile 文件都还在" \
  || fail "切换默认上游时动了 profile 文件"

echo "[1b] lc use 的参数校验"
if run_fail "$WORK/log-use2" use nosuch; then
  assert "切到不存在的上游会报错"      "$WORK/log-use2" "没有上游 'nosuch'"
  assert "报错里列出了可用的上游"      "$WORK/log-use2" "alpha, beta"
  assert "失败时 registry 没被改坏"    "$REG" '"default": "beta"'
fi
if run_fail "$WORK/log-use3" use; then
  assert "不给参数时给出用法"          "$WORK/log-use3" "用法: lc use <name>"
fi

# ─────────────────────────────────────────────────────────────────────────
echo "[2] lc ls：列清楚，但一个密钥值都不许打到 stdout"
run "$WORK/log-ls" ls
cat "$WORK/log-ls"
assert "列出了每个上游的名字"        "$WORK/log-ls" "alpha"
assert "列出了上游的模型 ID"         "$WORK/log-ls" "Qwen/Qwen3-32B"
assert "标出了当前默认上游"          "$WORK/log-ls" "默认: beta"
assert "标出了关思考模式的状态"      "$WORK/log-ls" "thinking=off"
assert "标出了自定义头的数量"        "$WORK/log-ls" "headers=1"
# 这几条是这一组的重点：ls 现在只显示 base URL（那是给人认地址用的），
# 但没有任何东西防止后来有人「顺手」把 key 也打出来。
refute "stdout 里没有 API Key 的值"          "$WORK/log-ls" "$CANARY_KEY"
refute "stdout 里没有自定义 header 的值"     "$WORK/log-ls" "$CANARY_HDR"
refute "stdout 里没有网关 master key 的值"   "$WORK/log-ls" "$CANARY_MK"

echo "[2b] 没有上游时 lc ls 给指引而不是报错"
mv "$REG" "$WORK/reg.saved"
echo '{"default": null, "gateway_port": 4000, "upstreams": {}}' > "$REG"
run "$WORK/log-ls2" ls
assert "空注册表时提示怎么开始" "$WORK/log-ls2" "lc init"
mv "$WORK/reg.saved" "$REG"

# ─────────────────────────────────────────────────────────────────────────
echo "[3] lc up / down / status：docker 参数拼装与网关探活"
# 假 docker：把 argv 记进文件。断言的是 lc 交给 docker 的是什么，而不是
# docker 做了什么——后者不是这个项目的责任，也不该在 CI 里真起容器。
cat > "$WORK/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
exit 0
EOF
chmod +x "$WORK/bin/docker"
export DOCKER_LOG="$WORK/docker.log"
: > "$DOCKER_LOG"

# 网关桩：真监听 $PORT 并对 /health/liveliness 回 200，这样 wait_gw 第一次就
# 成功。不起它的话 lc up 会老老实实等满 45 秒——那不是在测什么，只是在等。
python3 - "$PORT" > "$WORK/gw.log" 2>&1 <<'PY' &
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'{"status":"connected"}'
        self.send_response(200 if self.path.startswith("/health") else 404)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
GW_PID=$!
for _ in $(seq 1 50); do
  python3 - "$PORT" <<'PY' && break || sleep 0.2
import socket, sys
s = socket.socket()
s.settimeout(0.2)
sys.exit(0 if s.connect_ex(("127.0.0.1", int(sys.argv[1]))) == 0 else 1)
PY
done

run "$WORK/log-up" up
assert "up 拼出了 compose up -d --force-recreate" "$DOCKER_LOG" "compose up -d --force-recreate"
assert "up 在网关起来后给出就绪回执"              "$WORK/log-up" "网关就绪"
assert "回执里带上了网关地址"                     "$WORK/log-up" "http://127.0.0.1:$PORT"
# up 会先 sync 一遍：registry 改了但忘了 sync 的话，起来的网关配置是旧的
assert "up 之前重新生成了配置"                    "$CFG_TOML" 'model = "beta"'

run "$WORK/log-st" status
assert "status 拼出了 compose ps"     "$DOCKER_LOG" "compose ps"
assert "网关活着时 status 这么说"      "$WORK/log-st" "网关存活"

run "$WORK/log-down" down
assert "down 拼出了 compose down"      "$DOCKER_LOG" "compose down"

echo "[3b] 网关不可达时给一句干净的话，不是 traceback"
kill "$GW_PID" 2>/dev/null || true
wait "$GW_PID" 2>/dev/null || true
GW_PID=""
# 这里故意不要求退出码为 0：探活失败时把异常漏出来的话，退出码和输出都会变，
# 用 run 的话会以「lc status 执行失败」收场，指不到「吐了 traceback」这个真因。
run_any "$WORK/log-st2" status
assert "网关不可达时 status 明确说无响应" "$WORK/log-st2" "网关无响应"
refute "网关不可达时没有 traceback"       "$WORK/log-st2" "Traceback (most recent call last)"
refute "网关不可达时不冒充存活"           "$WORK/log-st2" "网关存活"

# ─────────────────────────────────────────────────────────────────────────
if [ "$fails" -gt 0 ]; then
  echo "=== 失败 $fails 项 ==="
  exit 1
fi
echo "=== 全部通过 ==="
