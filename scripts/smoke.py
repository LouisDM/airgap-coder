#!/usr/bin/env python3
"""协议层冒烟测试：直接打 LiteLLM 网关，不经过 Codex。

用法: python3 scripts/smoke.py <model_name>    例: python3 scripts/smoke.py qwen32b
判据: 第 3 步 (tool calling) 和第 5 步 (Responses 桥接) 必须过，否则 Codex 做不了底座。
"""
import json
import os
import pathlib
import sys
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
GW = "http://127.0.0.1:4000"
ENV_FILE = ROOT / ".env"

sys.path.insert(0, str(ROOT / "scripts"))
import probe  # noqa: E402  —— 探测请求体、断言与失败提示，与 `lc doctor` 共用一份


def abort(msg, hint):
    """配置缺失走这里 —— 给中文提示，不要甩 Python traceback。"""
    print("❌ " + msg)
    print("   → " + hint)
    sys.exit(2)


if not ENV_FILE.exists():
    abort("找不到 %s，读不到网关密钥" % ENV_FILE,
          "先跑 `lc init` 完成初始化，它会生成 .env 与 registry.json")

for line in ENV_FILE.read_text().splitlines():
    line = line.strip()
    if line and not line.startswith("#") and "=" in line:
        k, v = line.split("=", 1)
        os.environ.setdefault(k, v)

MASTER_KEY = os.environ.get("LITELLM_MASTER_KEY")
if not MASTER_KEY:
    abort(".env 里没有 LITELLM_MASTER_KEY，无法向网关鉴权",
          "跑 `lc init` 补齐（它会随机生成一个 master key 写进 .env），再 `lc up` 重启网关")

MODEL = sys.argv[1] if len(sys.argv) > 1 else "qwen32b"
AUTH = {"Authorization": "Bearer " + MASTER_KEY,
        "Content-Type": "application/json"}
passed, failed = [], []


def call(path, payload, stream=False):
    req = urllib.request.Request(GW + path, data=json.dumps(payload).encode(),
                                 headers=AUTH, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=180) as r:
            raw = r.read().decode()
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
    return raw if stream else json.loads(raw)


def ok(msg):
    print("  ✅ " + msg); passed.append(msg)


def no(msg, detail="", hint=""):
    print("  ❌ " + msg)
    if detail:
        print("     " + str(detail)[:500])
    if hint:
        print("     ↳ 怎么修: " + probe.hint(hint))
    failed.append((msg, hint))

print("=== 冒烟测试: model=%s ===" % MODEL)

print("[1/5] 网关存活")
try:
    urllib.request.urlopen(GW + "/health/liveliness", timeout=10).read()
    ok("gateway up")
except Exception as e:
    no("gateway 未响应", e, "gateway_down"); sys.exit(1)

print("[2/5] 基础 chat completion")
d = call("/v1/chat/completions", {"model": MODEL, "max_tokens": 64,
         "messages": [{"role": "user", "content": "只回复两个字：正常"}]})
if d.get("error"):
    # 第 2 步挂了，后面三步必然连带挂。继续跑只会把一个根因刷成四条失败项，
    # 把真正的线索埋掉，所以这里直接短路，和第 1 步一致。
    no("chat 失败", d["error"].get("message"), "chat_failed")
    print("\n=== 通过 %d / 失败 %d ===" % (len(passed), len(failed)))
    print("  基础 chat 都不通，后续 3 项不再执行 —— 先按上面的提示修这一条")
    sys.exit(1)
else:
    print("  -> " + (d["choices"][0]["message"].get("content") or "")[:80])
    ok("chat 通")

print("[3/5] tool calling（关键项 — Codex 全靠它读写文件）")
d = call("/v1/chat/completions", probe.chat_payload(MODEL))
good, key, detail = probe.check_tool_call(d)
if good:
    print("  -> tool_calls[0]: " + detail)
    ok("tool calling 正常（函数名与参数结构均合法）")
else:
    no(probe.title(key), detail, key)
leak = probe.reasoning_leak(d)
if leak:
    print("  ⚠️  思考模式似乎还开着（%s）" % leak)
    print("     ↳ 怎么修: " + probe.hint("thinking_on"))

print("[4/5] 流式 + tool call 增量拼装")
raw = call("/v1/chat/completions", {
    "model": MODEL, "max_tokens": 512, "stream": True, "tools": probe.TOOL_CHAT,
    "messages": [{"role": "user", "content": "读取 README.md。必须调用工具。"}]}, stream=True)
n = raw.count("tool_calls")
if n:
    ok("流式 tool_calls 分片正常 (%d chunks)" % n)
else:
    no("流式下没有 tool_calls 分片", raw[:300], "no_stream_chunks")

print("[5/5] /v1/responses 桥接（Codex 实际走这条路，最关键）")
d = call("/v1/responses", {"model": MODEL, "tools": probe.TOOL_RESP,
                           "input": "读取 config.toml。必须调用工具。"})
if d.get("error"):
    no("Responses 桥接失败 —— Codex 会跑不通", d["error"].get("message"), "bridge_failed")
else:
    calls = [o for o in d.get("output", []) if o.get("type") == "function_call"]
    if calls:
        print("  -> function_call: %s(%s)" % (calls[0].get("name"), calls[0].get("arguments")))
        ok("Responses→ChatCompletions 桥接 + 工具调用正常")
    else:
        types = [o.get("type") for o in d.get("output", [])]
        no("桥接通了但没产出 function_call，output types=%s" % types,
           "", "bridge_no_function_call")

print("\n=== 通过 %d / 失败 %d ===" % (len(passed), len(failed)))
for msg, hint in failed:
    print("  失败项: " + msg)
    if hint:
        print("    ↳ 怎么修: " + probe.hint(hint))
sys.exit(1 if failed else 0)
