#!/usr/bin/env bash
# 钉住 `lc doctor` 的上游探测行为。
#
# 本项目最常见的失败不是连不上，而是「连得上、聊天正常、tool_calls 恒为空」
# （vLLM 漏了 --enable-auto-tool-choice --tool-call-parser hermes）。doctor 必须
# 能把这种情况判成失败并给出启动参数，而不是报「可达」。
#
# 真实模型在 CI 里跑不了，但判据是纯逻辑：拿一个桩上游按各种方式作答，断言
# doctor 的结论。桩上游同时反向断言探测请求本身——不带 tools 就永远测不出工具
# 解析没开；不带该上游登记的 params，打出去的请求就和网关实际发的不是同一个配置。
#
# 用法: bash scripts/test-doctor-probe.sh     （零依赖，只用 Python 标准库）
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${PROBE_PORT:-8931}"

# 整份测试在临时目录里跑：bin/lc 的 ROOT 由自身路径推导，registry.json 和 .env
# 会落在 ROOT 下。复制一份出去，才不会覆盖开发机上真实的 registry.json / .env。
WORK="$(mktemp -d)"
STUB_PID=""
cleanup() {
  [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

cp -r "$REPO/bin" "$REPO/scripts" "$WORK/"
cp "$REPO/registry.example.json" "$WORK/registry.json"
cat > "$WORK/.env" <<EOF
LITELLM_MASTER_KEY=sk-probe-fake
KEY_INTRANET=fake-key
KEY_INTRANET_BASE=http://127.0.0.1:$PORT/v1
EOF

cat > "$WORK/stub.py" <<'PY'
"""按 argv[1] 指定的方式作答的桩上游，用来钉 doctor 的每个判定分支。"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

MODE = sys.argv[1]
PORT = int(sys.argv[2])

STATUS = {"http401": 401, "http404": 404, "http400": 400}


def build(body):
    if MODE == "error200":
        return {"error": {"message": "model not loaded"}}
    if MODE == "notjson":
        return None

    msg = {"role": "assistant", "content": "config.toml 大概长这样……"}
    if MODE in ("tools", "think", "badcall"):
        args = {"path": "config.toml"} if MODE != "badcall" else {"wrong": 1}
        msg = {"role": "assistant", "content": None, "tool_calls": [
            {"id": "call_1", "type": "function",
             "function": {"name": "read_file", "arguments": json.dumps(args)}}]}
    if MODE == "think":
        msg["reasoning_content"] = "让我想想……"

    # 反向断言：探测请求少了这两样，这个测试本身就失去意义，让它显式暴露。
    if not body.get("tools"):
        msg["content"] = "PROBE_MISSING_TOOLS"
        msg.pop("tool_calls", None)
    elif not body.get("chat_template_kwargs"):
        msg["content"] = "PROBE_MISSING_PARAMS"
        msg.pop("tool_calls", None)
    return {"choices": [{"message": msg}]}


class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(n) or b"{}")
        payload = build(body)
        out = b"not json at all" if payload is None else \
            json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(STATUS.get(MODE, 200))
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *a):
        pass


HTTPServer(("127.0.0.1", PORT), H).serve_forever()
PY

fails=0

run_doctor() {   # $1=桩模式 —— 起桩、跑 doctor、输出落到 $WORK/out
  python3 "$WORK/stub.py" "$1" "$PORT" &
  STUB_PID=$!
  for _ in $(seq 50); do
    if python3 -c "
import socket,sys
s=socket.socket()
s.settimeout(0.2)
sys.exit(s.connect_ex(('127.0.0.1',$PORT)))
" 2>/dev/null; then break; fi
    sleep 0.1
  done
  # doctor 目前一律 exit 0（退出码是否该变另议），失败与否只看输出内容。
  NO_COLOR=1 python3 "$WORK/bin/lc" doctor > "$WORK/out" 2>&1 || true
  kill "$STUB_PID" 2>/dev/null || true
  wait "$STUB_PID" 2>/dev/null || true
  STUB_PID=""
}

check() {        # check assert|refute <字符串> <失败说明>
  local mode="$1" needle="$2" why="$3"
  # -e 不能省：待查字符串里有以 `--` 开头的（vLLM 启动参数），否则会被当成 grep 选项
  if grep -qF -e "$needle" "$WORK/out"; then
    hit=1
  else
    hit=0
  fi
  if { [ "$mode" = assert ] && [ "$hit" = 1 ]; } ||
     { [ "$mode" = refute ] && [ "$hit" = 0 ]; }; then
    echo "  ✅ $why"
  else
    echo "  ❌ $why"
    echo "::error::$why"
    fails=$((fails + 1))
  fi
}

echo "[1] 桩上游只回文本，不回 tool_calls —— 这正是 vLLM 漏参数时的样子"
run_doctor text
check refute "PROBE_MISSING_TOOLS"  "探测请求带上了 tools（不带则测不出工具解析是否开启）"
check refute "PROBE_MISSING_PARAMS" "探测请求带上了该上游的 params（否则与网关实际请求不是同一个配置）"
check assert "tool calling 未生效"  "工具解析没开时判为失败，而不是「可达」"
check assert "--enable-auto-tool-choice" "失败时给出了可操作的 vLLM 启动参数"

echo "[2] 桩上游正常回 tool_calls"
run_doctor tools
check assert "tool calling 生效" "工具解析正常时判为通过"
check refute "tool calling 未生效" "正常时没有误报"

echo "[3] 回 tool_calls 但结构不合法 —— parser 选错而非没开"
run_doctor badcall
check assert "parser 可能选错了" "结构不合法与「没开」区分开了"

echo "[4] 回 tool_calls，且带 reasoning_content"
run_doctor think
check assert "思考模式似乎还开着" "思考模式没关时给出提示"

echo "[5] HTTP 200 但 body 是 error —— 部分推理框架会这么干"
run_doctor error200
check refute "tool calling 生效" "200 但 body 含 error 时不判为通过"

echo "[6] HTTP 200 但 body 不是 JSON"
run_doctor notjson
check assert "不是 JSON" "非 JSON 响应干净报错，不抛 traceback"
check refute "Traceback"  "没有未捕获异常"

echo "[7] 鉴权与地址错误分级为错误，而非一句笼统的 warn"
run_doctor http401
check assert "鉴权失败" "401 给出定向提示"
run_doctor http404
check assert "地址或模型 ID 不对" "404 给出定向提示"

echo "[8] 本机 Codex 版本与 Dockerfile 锁定版本的比对"
# 这段不需要桩上游（探测会失败，doctor 仍 exit 0），只看版本比对那几行。
# 用假 Dockerfile 钉 pin、用假 codex 钉本机版本，两者都在临时目录里。
mkdir -p "$WORK/docker" "$WORK/fakebin"

pin_version() { printf 'ARG CODEX_VERSION=%s\n' "$1" > "$WORK/docker/Dockerfile"; }

fake_codex() {   # $1 = `codex --version` 打印的内容；不传则删掉假 codex
  if [ "$#" -eq 0 ]; then
    rm -f "$WORK/fakebin/codex"
  else
    printf '#!/usr/bin/env bash\necho "%s"\n' "$1" > "$WORK/fakebin/codex"
    chmod +x "$WORK/fakebin/codex"
  fi
}

run_doctor_version() {
  PATH="$WORK/fakebin:$PATH" NO_COLOR=1 \
    python3 "$WORK/bin/lc" doctor > "$WORK/out" 2>&1 || true
}

pin_version 0.145.0

fake_codex "codex-cli 0.145.0"
run_doctor_version
check assert "codex 版本与 Dockerfile 锁定一致 (0.145.0)" "版本相同时判为一致"
check refute "不一致" "版本相同时不误报"

fake_codex "codex-cli 0.147.0"
run_doctor_version
check assert "本机 Codex 0.147.0 与 Dockerfile 锁定的 0.145.0 不一致" "版本不同时给出 warning"
check assert "npm i -g @openai/codex@0.145.0" "warning 附带可直接执行的对齐命令"

# 关键回归：两段式输出不能被前缀匹配吞掉。"0.145.0".startswith("0.14") 为真，
# 按前缀比会把它判成「一致」——而这正是本检查要防的静默通过。
fake_codex "codex-cli 0.14"
run_doctor_version
check assert "本机 Codex 0.14 与 Dockerfile 锁定的 0.145.0 不一致" "两段式版本不被前缀匹配误判为一致"

# 反过来，0.145 和 0.145.0 是同一个版本，补零后应当判一致。
fake_codex "codex-cli 0.145"
run_doctor_version
check assert "codex 版本与 Dockerfile 锁定一致" "省略末段的同一版本判为一致"

# 版本号解析不出来时，不能把随便一段文本当成版本号打进 warning
fake_codex "codex-cli (unknown build)"
run_doctor_version
check assert "无法读取本机 codex --version" "解析不出版本号时降级为明确提示"
check refute "不一致" "解析失败时不拿非版本号文本去比对"

# codex 根本没装：上面 tool 检查已经报过了，这里不该再刷一条版本 warning
fake_codex
run_doctor_version
check assert "codex 未安装" "没装 codex 时如实报告"
check refute "无法读取本机 codex --version" "没装 codex 时不重复刷版本提示"

if [ "$fails" -gt 0 ]; then
  echo "=== 失败 $fails 项 ==="
  exit 1
fi
echo "=== 全部通过 ==="
