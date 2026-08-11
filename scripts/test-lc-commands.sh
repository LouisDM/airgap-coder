#!/usr/bin/env bash
# 钉住这些命令的行为：
#   - use / ls / up / down / status（issue #12 第二梯队）
#   - test / e2e / logs / code（issue #12 第三梯队）
#   - `lc up` 的两条失败路径（issue #34 compose 退出码 / issue #35 等待预算）
#   - 网关端口的唯一真源（issue #40：registry.json 的 gateway_port 必须一路生效到
#     compose 的端口映射、codex 的 base_url 和 `lc test`，而不是各读各的）
#
# 第三梯队按 issue 里的分级刻意写得轻：test / e2e 本身就是测试入口，这里不去测
# 「测试跑得对不对」，只测它们**解析不了目标时干净失败**；logs 只测参数拼装；
# code 重点是 CODEX_HOME 不许指向用户的 ~/.codex。
#
# 这五个命令写坏了不会泄密，但会浪费大量排查时间，而且其中两条正好踩在项目
# 已知的坑上：
#   - `lc use` 切完之后 codex/config.toml 的默认 model 必须真的变。Codex 对
#     不存在的 profile 是**静默回落**到默认 model 的，切换没生效不会有任何报错，
#     表现成「以为在测 A，其实在测 B」。
#   - `lc status` 在网关不可达时要给一句干净的话，不是 Python traceback。
#
# 跑 docker 的那几条用一个假 docker 桩（记录 argv 到文件，退出码可控），断言的是
# 「参数拼装对不对」和「lc 有没有看 docker 的退出码」；网关侧用真的 socket 桩，
# 三种形态各一个：活着（HTTP 200）、没人监听（连接立刻被拒）、accept 了但从不
# 回应（模拟防火墙 DROP，这是 issue #35 里那个 6 倍偏差的来源）。
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
mkdir -p "$SRC/bin" "$SRC/scripts" "$WORK/bin"
cp "$REPO/bin/lc" "$SRC/bin/lc"
# lc e2e 会去调它。这个脚本本身要真模型才跑得完（所以是 ci-exempt），但它启动
# Codex 之前那段「往子进程里放哪些环境变量」用假 codex 桩就能钉住，见 [6e]。
cp "$REPO/scripts/test-codex.sh" "$SRC/scripts/test-codex.sh"
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
# 老版本 .env.example 里带着这一行。留着它，用来钉住「端口的源已经不是 .env 了」
# （issue #40）：registry 里的端口是现取的 $PORT，注入给 compose 的必须是那个。
GATEWAY_PORT=4000
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

# ── 网关桩：三种形态，都监听 registry 里那个 $PORT ────────────────────────
# 活着的那个对 /health/liveliness 回 200，让 wait_gw 第一次探活就成功；不起它的话
# lc up 会老老实实等满默认预算——那不是在测什么，只是在等。
cat > "$WORK/gw_http.py" <<'PY'
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

# 黑洞桩：accept 之后既不回应也不关闭，客户端只能等到自己的超时。内网防火墙对
# 未放行端口通常是 DROP 而不是 REJECT，表现就是这个——issue #35 的最坏情况。
cat > "$WORK/gw_blackhole.py" <<'PY'
import socket, sys

srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", int(sys.argv[1])))
srv.listen(32)
held = []                      # 留住引用，别让 GC 关掉连接（关掉就变成"立刻失败"）
while True:
    conn, _ = srv.accept()
    held.append(conn)
PY

start_gw() {  # start_gw <gw_http.py|gw_blackhole.py>
  python3 "$WORK/$1" "$PORT" > "$WORK/gw.log" 2>&1 &
  GW_PID=$!
  local i
  for i in $(seq 1 50); do
    python3 - "$PORT" <<'PY' && return 0 || sleep 0.2
import socket, sys
s = socket.socket()
s.settimeout(0.2)
sys.exit(0 if s.connect_ex(("127.0.0.1", int(sys.argv[1]))) == 0 else 1)
PY
  done
  echo "::error::网关桩 $1 没能在 10s 内监听上 $PORT"
  exit 1
}

stop_gw() {
  [ -n "$GW_PID" ] || return 0
  kill "$GW_PID" 2>/dev/null || true
  wait "$GW_PID" 2>/dev/null || true
  GW_PID=""
  # 端口彻底释放之后再往下走，否则「连接被拒」那几条会偶发地连上前一个桩
  local i
  for i in $(seq 1 50); do
    python3 - "$PORT" <<'PY' && return 0 || sleep 0.2
import socket, sys
s = socket.socket()
s.settimeout(0.2)
sys.exit(0 if s.connect_ex(("127.0.0.1", int(sys.argv[1]))) != 0 else 1)
PY
  done
}

# 假 docker：把 argv 记进文件，退出码由 $DOCKER_RC 控制。断言的是「lc 交给 docker
# 的是什么」和「lc 有没有看它的退出码」，而不是 docker 做了什么——后者不是这个
# 项目的责任，也不该在 CI 里真起容器。
cat > "$WORK/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
# 端口映射走的是 compose 的 ${GATEWAY_PORT} 插值，不在 argv 里，所以单看参数
# 拼装看不出端口对不对（issue #40 就是这么漏过去的）。把注入的环境变量也记下来。
# 用 ${VAR-} 而不是 ${VAR:-}：要能区分「没注入」和「注入了空值」。
printf 'env GATEWAY_PORT=%s\n' "${GATEWAY_PORT-<unset>}" >> "$DOCKER_LOG"
if [ "${DOCKER_RC:-0}" != "0" ]; then
  echo "Error response from daemon: driver failed programming external" >&2
  echo "connectivity: Bind for 0.0.0.0:4000 failed: port is already allocated" >&2
fi
exit "${DOCKER_RC:-0}"
EOF
chmod +x "$WORK/bin/docker"
export DOCKER_LOG="$WORK/docker.log"
export DOCKER_RC=0
: > "$DOCKER_LOG"

# elapsed_of <等待预算> <日志> <lc 参数...>：跑一次，回填 $ELAPSED 和 $RC。
# 预算走参数而不是 `LC_GATEWAY_WAIT=x elapsed_of ...`：bash 里给**函数**加的变量
# 前缀在函数返回后依然留着，会悄悄泄进后面几节。
elapsed_of() {
  local budget="$1" log="$2" t0 rc; shift 2
  t0="$(date +%s)"
  NO_COLOR=1 LC_GATEWAY_WAIT="$budget" PATH="$WORK/bin:$PATH" "${LC[@]}" "$@" \
    < /dev/null > "$log" 2>&1 && rc=0 || rc=$?
  ELAPSED=$(( $(date +%s) - t0 ))
  RC="$rc"
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
start_gw gw_http.py

: > "$DOCKER_LOG"
run "$WORK/log-up" up
assert "up 拼出了 compose up -d --force-recreate" "$DOCKER_LOG" "compose up -d --force-recreate"
# ── 端口的唯一真源（issue #40）─────────────────────────────────────────────
# registry 里的 gateway_port 必须一路生效到 compose 的端口映射上。原来没有任何
# 代码写 GATEWAY_PORT，容器发布在 4000、而 status / code / doctor 去连 registry
# 里那个端口——「status 说死了、test 说活着」。$PORT 是现取的空闲端口，必然不是
# 4000，所以这几条断言不会在「碰巧都是 4000」的情况下假通过。
assert "up 把 registry 的端口注入给了 compose"   "$DOCKER_LOG" "env GATEWAY_PORT=$PORT"
refute "注入的不是写死的 4000"                   "$DOCKER_LOG" "env GATEWAY_PORT=4000"
refute "GATEWAY_PORT 确实注入了（不是没设）"      "$DOCKER_LOG" "env GATEWAY_PORT=<unset>"
assert "codex 配置的 base_url 也用同一个端口"    "$CFG_TOML" "base_url = \"http://127.0.0.1:$PORT/v1\""
# 沙箱的 .env 里特意留了一行老版本的 GATEWAY_PORT=4000（.env.example 曾经带着它）。
# 上面那条断言在这个前提下才有意义：它钉的是「.env 不再是端口的源」，而不只是
# 「两处碰巧一致」。改成「sync 把端口同步进 .env」的实现会让这条继续绿，但那种
# 实现下手改 .env 仍然会漂移——所以还要看 test-lc-secrets.sh 里那条「lc 从不往
# .env 写 GATEWAY_PORT」。
assert "沙箱 .env 里确实留着老版本那行"          "$ENVF" "GATEWAY_PORT=4000"
assert "up 在网关起来后给出就绪回执"              "$WORK/log-up" "网关就绪"
# 回执里那个数是 wait_gw 的返回值。网关立刻就应答的话它必须是 1s——报成预算
# 上限或者 0s 都说明返回的不是「真的等了多久」（issue #35）。
assert "回执报的是真实等待秒数"                   "$WORK/log-up" "网关就绪 (1s)"
assert "回执里带上了网关地址"                     "$WORK/log-up" "http://127.0.0.1:$PORT"
# up 会先 sync 一遍：registry 改了但忘了 sync 的话，起来的网关配置是旧的
assert "up 之前重新生成了配置"                    "$CFG_TOML" 'model = "beta"'

run "$WORK/log-st" status
assert "status 拼出了 compose ps"     "$DOCKER_LOG" "compose ps"
assert "网关活着时 status 这么说"      "$WORK/log-st" "网关存活"

run "$WORK/log-down" down
assert "down 拼出了 compose down"      "$DOCKER_LOG" "compose down"

echo "[3b] 网关不可达时给一句干净的话，不是 traceback"
stop_gw
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
# LC_GATEWAY_WAIT 把等待预算开成可注入之后，1 秒就能走到。
#
# 网关桩已经在 [3b] 里被杀掉了，所以这个端口现在没人监听：连接立刻被拒，
# 探活是毫秒级的，不会真等 1 秒以上。
elapsed_of 1 "$WORK/log-up-fail" up
cat "$WORK/log-up-fail"
# 提示语和实际等待是两件事：wait_gw 可能照样等满 45 秒，而 cmd_up 仍然按注入的
# 值报「未在 1s 内就绪」。所以除了措辞，还要断言真的没等那么久。
# 阈值给得宽松（15s）：这条测的是「注入生效了」，不是精确计时。
[ "$ELAPSED" -lt 15 ] \
  && pass "注入的超时真的生效了（失败分支 ${ELAPSED}s 内返回，不是 45s）" \
  || fail "LC_GATEWAY_WAIT 只改了提示语，wait_gw 仍然等了 ${ELAPSED}s"
# 退出码（issue #34）：原来 up 无论成败都退 0，`lc up && lc test` 会照样往下跑，
# 站点部署脚本没法判断网关到底起没起。
[ "$RC" -ne 0 ] \
  && pass "网关没起来时 lc up 以非零退出码收场（RC=$RC）" \
  || fail "网关没起来，lc up 却退了 0——部署脚本无法判断成败"
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
print("budget=%d default=%d probe=%d"
      % (mod.gw_wait_seconds(), mod.GW_WAIT_DEFAULT, mod.GW_PROBE_TIMEOUT))
PY
}
probe_wait ""    > "$WORK/log-w0" 2>&1
probe_wait "120" > "$WORK/log-w1" 2>&1
probe_wait "abc" > "$WORK/log-w2" 2>&1
probe_wait "0"   > "$WORK/log-w3" 2>&1
cat "$WORK/log-w0" "$WORK/log-w1" "$WORK/log-w2" "$WORK/log-w3"
assert "不设时用默认 45"           "$WORK/log-w0" "budget=45 default=45"
assert "设成 120 时真的是 120"     "$WORK/log-w1" "budget=120"
assert "非法值说明了按默认处理"    "$WORK/log-w2" "不是正整数"
assert "非法值回落到默认 45"       "$WORK/log-w2" "budget=45"
assert "0 也当非法值处理"          "$WORK/log-w3" "budget=45"
# 单次探活的超时得是个独立且明显更小的常量：把它和预算写成同一个值，等于回到
# 「一轮≈一秒」那个不成立的模型。
assert "单次探活超时是独立的更小常量" "$WORK/log-w0" "probe=5"

echo "[3e] lc help 里提到了这个变量"
# 只有测试知道的环境变量等于一个暗门：用户撞上 45 秒超时时不会知道有得调。
run "$WORK/log-help" help
assert "help 列出了 LC_GATEWAY_WAIT" "$WORK/log-help" "LC_GATEWAY_WAIT"

# ─────────────────────────────────────────────────────────────────────────
echo "[3f] compose 自己就失败了：立刻停下，别再等满预算（issue #34）"
# 端口被占、镜像没 docker load、compose 文件语法错——这几条在内网首次部署很常见，
# 共同点是 docker 自己已经把原因打在屏幕上了。原来 cmd_up 丢掉这个退出码，于是
# 一个已经诊断清楚的错误变成了预算耗尽之后的一句「看日志: lc logs」，而容器根本
# 没起来、那份日志是空的，真正的原因早就滚出屏幕了。
export DOCKER_RC=1
: > "$DOCKER_LOG"
elapsed_of 5 "$WORK/log-up-rc" up
cat "$WORK/log-up-rc"
assert "仍然试过 compose up"  "$DOCKER_LOG" "compose up -d --force-recreate"
[ "$RC" -ne 0 ] \
  && pass "compose 失败时 lc up 以非零退出码收场（RC=$RC）" \
  || fail "compose 已经失败，lc up 却退了 0"
# 这条是这一节的重点：不能进等待循环。只查措辞的话，「先等满预算再报同一句话」
# 也能过——而那正是原来的行为。
[ "$ELAPSED" -lt 4 ] \
  && pass "compose 失败时不进等待循环（${ELAPSED}s 内返回）" \
  || fail "compose 已经失败，lc up 还等了 ${ELAPSED}s"
assert "报错里带上了 docker 的退出码"  "$WORK/log-up-rc" "退出码 1"
assert "给了常见原因"                  "$WORK/log-up-rc" "端口被占"
refute "不再谎称等过预算"              "$WORK/log-up-rc" "网关未在"
# 容器没起来，那份日志是空的：把人指过去只是多浪费一步
refute "不把人指向空的 lc logs"        "$WORK/log-up-rc" "lc logs"
refute "失败时不冒充就绪"              "$WORK/log-up-rc" "网关就绪"
refute "失败时没有 traceback"          "$WORK/log-up-rc" "Traceback (most recent call last)"

echo "[3g] compose 报非零但网关其实活着：不误杀"
# `--force-recreate` 删旧容器时可能报个无害的错。多一次 HTTP 探测换掉这个误伤，
# 否则「看退出码」这个修复会把一批本来能用的启动判成失败。
start_gw gw_http.py
elapsed_of 5 "$WORK/log-up-rc2" up
cat "$WORK/log-up-rc2"
[ "$RC" -eq 0 ] \
  && pass "网关活着时不因为 compose 的退出码失败" \
  || fail "网关明明活着，lc up 却因为 compose 退出码 1 判了死刑（RC=$RC）"
assert "照常给出就绪回执"        "$WORK/log-up-rc2" "网关就绪"
# 但不能一声不吭：那个非零退出码仍然是个信号，用户该知道
assert "同时提了 compose 的退出码" "$WORK/log-up-rc2" "退出码 1"
refute "不再报 compose up 失败"    "$WORK/log-up-rc2" "docker compose up 失败"
export DOCKER_RC=0

echo "[3h] 等待预算按墙上时钟算，不按轮数（issue #35）"
# 黑洞桩：accept 之后从不回应，探活只能等到自己的超时。这是内网最常见的不可达
# 形态（防火墙对未放行端口 DROP 而不是 REJECT），也是原实现偏差最大的地方——
# 「45 轮」在这种网络下实测约 271 秒，而提示语说的是「未在 45s 内就绪」。
stop_gw
start_gw gw_blackhole.py
elapsed_of 2 "$WORK/log-up-bh" up
cat "$WORK/log-up-bh"
assert "黑洞网关最终被判为未就绪" "$WORK/log-up-bh" "❌ 网关未在 2s 内就绪"
[ "$RC" -ne 0 ] \
  && pass "黑洞网关下 lc up 以非零退出码收场（RC=$RC）" \
  || fail "黑洞网关下 lc up 退了 0"
# 按轮数算的话这里是 2 × (探活 5s + sleep 1s) = 12s。这条断言直接钉住
# 「预算是墙上时钟」这个不变量，改回轮数模型就会红。
[ "$ELAPSED" -lt 8 ] \
  && pass "预算是墙上时钟：说 2s 就 ${ELAPSED}s 返回，不是 2 轮 ×6s" \
  || fail "等了 ${ELAPSED}s——预算又变回按轮数计了"
# 更细一层：单次探活的超时必须收进剩余预算。不收的话第一次探活就要花 5s，
# 「最多等 2s」还是做不到——上面那条 8s 的阈值放得过它，这条放不过。
[ "$ELAPSED" -lt 4 ] \
  && pass "单次探活超时收进了剩余预算（${ELAPSED}s ≤ 预算 + 余量）" \
  || fail "单次探活冲出了预算：说 2s，实际 ${ELAPSED}s"
stop_gw

echo "[3i] registry 里的 gateway_port 写坏了：说人话，不静默回落到 4000（issue #40）"
# 端口现在是唯一真源，读不出来时回落到 4000 等于把 issue #40 那个形态原样重演一遍
# （网关在一个端口上，诊断命令看另一个），而且这次连 registry 都不指向真相。
cp "$REG" "$WORK/reg.saved-port"
python3 - "$REG" <<'PY'
import json, sys
reg = json.load(open(sys.argv[1], encoding="utf-8"))
reg["gateway_port"] = "四千"
json.dump(reg, open(sys.argv[1], "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY
run_any "$WORK/log-badport" status
cat "$WORK/log-badport"
assert "坏端口时点名了是哪个字段"   "$WORK/log-badport" "gateway_port"
refute "坏端口时没有 traceback"     "$WORK/log-badport" "Traceback (most recent call last)"
refute "坏端口时不静默按 4000 继续" "$WORK/log-badport" "http://127.0.0.1:4000"
cp "$WORK/reg.saved-port" "$REG"

# ─────────────────────────────────────────────────────────────────────────
echo "[4] lc test / lc e2e：解析不了目标时干净失败（issue #12 第三梯队）"
# 这两个是测试入口，它们的输出正是用来做判断的，所以「拿着一个不存在的名字接着
# 跑」在这里代价最大——Codex 对不存在的 profile 静默回落到默认 model，表现成
# 「以为在测 A 其实在测 B」。真跑测试需要活的网关和真模型，CI 没有，也不该测
# 「测试跑得对不对」；这里只钉住三条解析失败路径。
#
# 真实的 smoke.py / test-codex.sh 复制进沙箱：不复制的话 lc 会去调一个不存在的
# 脚本，报的是「文件找不到」，那条路径测不到任何产品行为。
mkdir -p "$SRC/scripts"
cp "$REPO/scripts/smoke.py" "$REPO/scripts/probe.py" "$REPO/scripts/test-codex.sh" \
   "$SRC/scripts/"

for c in test e2e; do
  echo "  -- lc $c --"
  if run_fail "$WORK/log-$c-bad" "$c" nosuch; then
    assert "lc $c 挡下不存在的上游"     "$WORK/log-$c-bad" "没有上游 'nosuch'"
    assert "并列出可用的上游"            "$WORK/log-$c-bad" "alpha, beta"
  fi
done

echo "[4b] 没有默认上游时不许吐 traceback"
# 原来 reg.get("default") 是 None 会一路传进 subprocess，以
# `TypeError: expected str ... not NoneType` 收场——用户看到的是一段 Python 栈。
mv "$REG" "$WORK/reg.saved"
python3 - "$REG" "$WORK/reg.saved" <<'PY'
import json, sys
reg = json.load(open(sys.argv[2], encoding="utf-8"))
reg["default"] = None
json.dump(reg, open(sys.argv[1], "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY
for c in test e2e; do
  if run_fail "$WORK/log-$c-nodef" "$c"; then
    assert "lc $c 说清了没有默认上游"   "$WORK/log-$c-nodef" "没有默认上游"
    assert "并给出怎么选"                "$WORK/log-$c-nodef" "lc use <name>"
    assert "也给出可用的上游"            "$WORK/log-$c-nodef" "alpha, beta"
  fi
  refute "lc $c 没有 TypeError"          "$WORK/log-$c-nodef" "TypeError"
done

echo "[4c] 空注册表时指向 lc init"
echo '{"default": null, "gateway_port": 4000, "upstreams": {}}' > "$REG"
for c in test e2e; do
  if run_fail "$WORK/log-$c-empty" "$c"; then
    assert "lc $c 在空注册表时指向 lc init" "$WORK/log-$c-empty" "lc init"
  fi
done
mv "$WORK/reg.saved" "$REG"

echo "[4d] lc e2e 的 profile 防呆：一个 profile 都没有时也要说人话"
# test-codex.sh 里那个防呆是最后一道线（它也能被单独调用）。原来 `ls` 没匹配到
# 任何文件时 xargs 会拿空输入去调 basename，真正的提示前先蹦一行
# "basename: missing operand"，读的人会以为脚本自己坏了。
# 有 profile 那条：沙箱里 alpha / beta 都 sync 过了
bash "$SRC/scripts/test-codex.sh" nosuch > "$WORK/log-e2e-prof" 2>&1 || true
cat "$WORK/log-e2e-prof"
assert "挡下不存在的 profile"           "$WORK/log-e2e-prof" "profile 'nosuch' 不存在"
assert "并列出可用的 profile"           "$WORK/log-e2e-prof" "alpha"
refute "没有 basename 的报错噪音"       "$WORK/log-e2e-prof" "basename:"
# 一个 profile 都没有那条：CODEX_HOME 由脚本自身路径推导（它会覆盖外面传的值），
# 所以要把脚本放到一个没有 codex/ 兄弟目录的地方去跑。
mkdir -p "$WORK/iso/scripts"
cp "$REPO/scripts/test-codex.sh" "$WORK/iso/scripts/"
cp "$ENVF" "$WORK/iso/.env"
bash "$WORK/iso/scripts/test-codex.sh" nosuch > "$WORK/log-e2e-noprof" 2>&1 || true
cat "$WORK/log-e2e-noprof"
refute "空 CODEX_HOME 时也没有 basename 噪音" "$WORK/log-e2e-noprof" "basename:"
assert "说清了一个 profile 都没有"      "$WORK/log-e2e-noprof" "一个 profile 都没有"
assert "并指向 lc sync"                 "$WORK/log-e2e-noprof" "lc sync"

echo "[4e] lc test 打的是 registry 里那个端口，不是写死的 4000（issue #40）"
# smoke.py 是 `lc test` 的全部内容，而它原来写死 GW = http://127.0.0.1:4000。
# 端口改成非 4000 之后，`lc status` 探 registry 那个端口说「无响应」、`lc test`
# 探 4000 说「连上了」——同一台机器上两个诊断命令互相矛盾，两个都「没坏」。
# 网关桩此刻是停的，所以第 1 步必然失败；要断言的是它**冲哪个地址**去失败的。
if run_fail "$WORK/log-test-port" test alpha; then
  assert "smoke 探的是 registry 里的端口" "$WORK/log-test-port" "http://127.0.0.1:$PORT"
  refute "smoke 没去探写死的 4000"        "$WORK/log-test-port" "127.0.0.1:4000"
  assert "网关不通时给的是判定而不是栈"    "$WORK/log-test-port" "gateway 未响应"
fi

# ─────────────────────────────────────────────────────────────────────────
echo "[5] lc logs：参数拼装（薄封装，不真起容器）"
: > "$DOCKER_LOG"
run "$WORK/log-logs" logs
assert "logs 拼出了 compose logs -f"    "$DOCKER_LOG" "compose logs -f"
: > "$DOCKER_LOG"
run "$WORK/log-logs2" logs --tail 5
assert "透传了额外参数给 docker compose" "$DOCKER_LOG" "compose logs -f --tail 5"

# ─────────────────────────────────────────────────────────────────────────
echo "[6] lc code：网关没起来就别启动 Codex，CODEX_HOME 不许指向 ~/.codex"
# 假 codex：把 CODEX_HOME 和 argv 记进文件，同时留一个「我被启动过」的痕迹。
# 光看输出不够——要断言的是「没起来时压根没启动 Codex」。
# 另外把整份环境 dump 出来，[6c] 要按值搜哨兵（issue #42）。
cat > "$WORK/bin/codex" <<'EOF'
#!/usr/bin/env bash
{ echo "CODEX_HOME=$CODEX_HOME"; echo "argv=$*"; } >> "$CODEX_LOG"
env | sort > "$CODEX_ENV_LOG"
exit 0
EOF
chmod +x "$WORK/bin/codex"
export CODEX_LOG="$WORK/codex.log"
export CODEX_ENV_LOG="$WORK/codex.env"
: > "$CODEX_LOG"
: > "$CODEX_ENV_LOG"

echo "[6a] 网关不可达：不启动 Codex"
# 网关桩在 [3h] 末尾已经停掉了，这个端口现在没人监听。
if run_fail "$WORK/log-code-dead" code; then
  assert "明确说网关没起来"   "$WORK/log-code-dead" "网关没起来"
  assert "并指向 lc up"       "$WORK/log-code-dead" "lc up"
fi
if [ -s "$CODEX_LOG" ]; then
  cat "$CODEX_LOG"
  fail "网关不可达却还是把 Codex 启起来了"
else
  pass "网关不可达时压根没启动 Codex"
fi

echo "[6b] 网关活着：CODEX_HOME 指向仓库内的 codex/，profile 是当前默认上游"
# CODEX_HOME 写错会污染用户全局的 ~/.codex（会话库、配置），而且是静默发生的。
start_gw gw_http.py
: > "$CODEX_LOG"
run "$WORK/log-code" code --sandbox read-only
cat "$CODEX_LOG"
assert "CODEX_HOME 指向仓库内的 codex/" "$CODEX_LOG" "CODEX_HOME=$SRC/codex"
refute "CODEX_HOME 不是用户的 ~/.codex" "$CODEX_LOG" "$HOME/.codex"
assert "带上了当前默认上游的 profile"    "$CODEX_LOG" "--profile beta"
assert "透传了额外参数给 codex"          "$CODEX_LOG" "--sandbox read-only"

echo "[6c] lc code 只把 Codex 声明要用的 env_key 交给它，不是整份 .env（issue #42）"
# 这个子进程是 approval_policy = "never" 的 Codex：模型输出的 shell 命令直接执行。
# 整份 .env 注入进去，工作区里一个带提示注入的文件就能让它 `env` 读走所有上游的
# 凭证和内网地址——包括当前 profile 根本没在用的那些。
# 钉的是「没多给」，不是「给够了」——前者才是这条 issue 的不变量。
assert "provider 的 env_key 传下去了"        "$CODEX_ENV_LOG" "LITELLM_MASTER_KEY=sk-$CANARY_MK"
refute "没带上当前上游的 API Key"            "$CODEX_ENV_LOG" "$CANARY_KEY"
refute "没带上自定义 HTTP 头的值"            "$CODEX_ENV_LOG" "$CANARY_HDR"
refute "没带上其它上游的内网地址"            "$CODEX_ENV_LOG" "beta.your-intranet.local"
if grep -q '^KEY_' "$CODEX_ENV_LOG"; then
  grep '^KEY_' "$CODEX_ENV_LOG" | sed 's/=.*/=<省略>/'
  fail "Codex 的环境里还有 KEY_* 上游凭证变量"
else
  pass "Codex 的环境里一个 KEY_* 都没有"
fi

echo "[6d] 变异测试：把整份 .env 注入的写法改回去，[6c] 必须变红"
# 没有这条，[6c] 可能只是碰巧绿的（比如哨兵拼错、env dump 没生成）。
MUT="$WORK/mutant"
rm -rf "$MUT"; cp -r "$SRC" "$MUT"
python3 - "$MUT/bin/lc" <<'PY'
import sys
p = sys.argv[1]
src = open(p, encoding="utf-8").read()
old = ("    for k in sorted(needed):\n"
       "        if k in src:\n"
       "            env[k] = src[k]\n")
if old not in src:
    # 重构过就直接红，而不是让变异测试静默失效、[6c] 从此没人替它把关
    sys.exit("::error::变异测试找不到注入点，codex_env() 被改过了——请同步更新本处")
open(p, "w", encoding="utf-8").write(src.replace(old, "    env.update(src)\n"))
PY
: > "$CODEX_ENV_LOG"
NO_COLOR=1 PATH="$WORK/bin:$PATH" python3 "$MUT/bin/lc" code < /dev/null > "$WORK/log-code-mut" 2>&1 || true
if grep -qF "$CANARY_KEY" "$CODEX_ENV_LOG"; then
  pass "变异版本确实泄漏了上游凭证，说明 [6c] 真的在把关"
else
  cat "$WORK/log-code-mut"
  fail "变异版本也没泄漏——[6c] 的断言是空的，没在测东西"
fi
rm -rf "$MUT"

echo "[6e] lc e2e 走的是另一条路（test-codex.sh），同样不许整份 source .env"
# test-codex.sh 真跑完要活网关和真模型，所以它是 ci-exempt；但「给 Codex 哪些
# 环境变量」这一段在启动 codex 之前就定了，用同一个假桩就能钉住。后面的结果
# 校验必然失败（桩不会真去改 calc.py），退出码不看。
: > "$CODEX_ENV_LOG"
run_any "$WORK/log-e2e-env" e2e alpha
if [ -s "$CODEX_ENV_LOG" ]; then
  assert "e2e 也传了 provider 的 env_key"  "$CODEX_ENV_LOG" "LITELLM_MASTER_KEY=sk-$CANARY_MK"
  refute "e2e 没带上上游的 API Key"        "$CODEX_ENV_LOG" "$CANARY_KEY"
  refute "e2e 没带上自定义 HTTP 头的值"    "$CODEX_ENV_LOG" "$CANARY_HDR"
  if grep -q '^KEY_' "$CODEX_ENV_LOG"; then
    grep '^KEY_' "$CODEX_ENV_LOG" | sed 's/=.*/=<省略>/'
    fail "e2e 起的 Codex 环境里还有 KEY_* 上游凭证变量"
  else
    pass "e2e 起的 Codex 环境里一个 KEY_* 都没有"
  fi
else
  cat "$WORK/log-e2e-env"
  fail "e2e 压根没走到启动 Codex 那一步，这条断言等于没测"
fi
stop_gw

# ─────────────────────────────────────────────────────────────────────────
if [ "$fails" -gt 0 ]; then
  echo "=== 失败 $fails 项 ==="
  exit 1
fi
echo "=== 全部通过 ==="
