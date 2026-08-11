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
echo "[3c] lc up 的失败分支：网关起不来（issue #27）"
# 这条分支是用户最常撞上的那条（配置写错、端口被占、镜像没 load），而它原来
# 恰恰是唯一没有断言的：走到它得真等 45 秒，那不是在测什么，只是在等。
# LC_GATEWAY_WAIT 把等待轮数开成可注入之后，1 秒就能走到。
#
# 网关桩已经在 [3b] 里被杀掉了，所以这个端口现在没人监听：连接立刻被拒，
# 一轮就结束，不会真等 1 秒以上。
# up 的退出码本来就是 0（它只报告状态、不 sys.exit），所以只看输出。
T0="$(date +%s)"
NO_COLOR=1 LC_GATEWAY_WAIT=1 PATH="$WORK/bin:$PATH" "${LC[@]}" up \
  < /dev/null > "$WORK/log-up-fail" 2>&1 || true
ELAPSED=$(( $(date +%s) - T0 ))
cat "$WORK/log-up-fail"
# 提示语和实际等待是两件事：wait_gw 可能照样等满 45 秒，而 cmd_up 仍然按注入的
# 值报「未在 1s 内就绪」。所以除了措辞，还要断言真的没等那么久。
# 阈值给得宽松（15s）：这条测的是「注入生效了」，不是精确计时。
[ "$ELAPSED" -lt 15 ] \
  && pass "注入的超时真的生效了（失败分支 ${ELAPSED}s 内返回，不是 45s）" \
  || fail "LC_GATEWAY_WAIT 只改了提示语，wait_gw 仍然等了 ${ELAPSED}s"
# 带上 ❌ 一起断言：只查措辞的话，把 err 改成 ok 不会有任何东西变红——
# 那会让一次失败的启动读起来像成功。
assert "网关起不来时说清了超时，且是以失败的形式" \
  "$WORK/log-up-fail" "❌ 网关未在 1s 内就绪"
assert "并指向 lc logs"            "$WORK/log-up-fail" "lc logs"
refute "失败时不冒充就绪"          "$WORK/log-up-fail" "网关就绪"
refute "失败时没有 traceback"      "$WORK/log-up-fail" "Traceback (most recent call last)"
# 超时秒数要来自实际用的值。写死 45 的话，调过 LC_GATEWAY_WAIT 的人会读到一句
# 和现实不符的话——排查时最耽误人的就是这种话。
refute "报的秒数不是写死的 45"     "$WORK/log-up-fail" "网关未在 45s 内就绪"
# 调过的人不需要再被建议调大；这条提示只在用默认值时才有意义
refute "显式设过超时的人不再被建议调大" "$WORK/log-up-fail" "可以调大"

echo "[3d] LC_GATEWAY_WAIT 的取值处理"
# 默认值和非法值的处理不能用 lc up 测——那要真等 45 秒。直接把 bin/lc 当模块
# 载进来问它（模块级没有副作用，main() 有 __name__ 守卫）。
# 默认值本身也要断言：不小心把默认改成 1，慢内网上的 lc up 会无故报失败，
# 而没有任何东西会因此变红。
# 非法值不许静默回落：Codex 对不存在的 profile 静默回落已经坑过人，同样的形态
# 不该在这里重演。
probe_wait() {  # probe_wait <LC_GATEWAY_WAIT 的值>
  LC_GATEWAY_WAIT="$1" NO_COLOR=1 python3 - "$SRC/bin/lc" <<'PY'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("lc", sys.argv[1])
spec = importlib.util.spec_from_file_location("lc", sys.argv[1], loader=loader)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
print("tries=%d default=%d" % (mod.gw_wait_tries(), mod.GW_WAIT_DEFAULT))
PY
}
probe_wait ""    > "$WORK/log-w0" 2>&1
probe_wait "120" > "$WORK/log-w1" 2>&1
probe_wait "abc" > "$WORK/log-w2" 2>&1
probe_wait "0"   > "$WORK/log-w3" 2>&1
cat "$WORK/log-w0" "$WORK/log-w1" "$WORK/log-w2" "$WORK/log-w3"
assert "不设时用默认 45"           "$WORK/log-w0" "tries=45 default=45"
assert "设成 120 时真的是 120"     "$WORK/log-w1" "tries=120"
assert "非法值说明了按默认处理"    "$WORK/log-w2" "不是正整数"
assert "非法值回落到默认 45"       "$WORK/log-w2" "tries=45"
assert "0 也当非法值处理"          "$WORK/log-w3" "tries=45"

echo "[3e] lc help 里提到了这个变量"
# 只有测试知道的环境变量等于一个暗门：用户撞上 45 秒超时时不会知道有得调。
run "$WORK/log-help" help
assert "help 列出了 LC_GATEWAY_WAIT" "$WORK/log-help" "LC_GATEWAY_WAIT"

# ─────────────────────────────────────────────────────────────────────────
if [ "$fails" -gt 0 ]; then
  echo "=== 失败 $fails 项 ==="
  exit 1
fi
echo "=== 全部通过 ==="
