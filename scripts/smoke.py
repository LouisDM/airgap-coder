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

for line in (ROOT / ".env").read_text().splitlines():
    line = line.strip()
    if line and not line.startswith("#") and "=" in line:
        k, v = line.split("=", 1)
        os.environ.setdefault(k, v)

MODEL = sys.argv[1] if len(sys.argv) > 1 else "qwen32b"
AUTH = {"Authorization": "Bearer " + os.environ["LITELLM_MASTER_KEY"],
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


def no(msg, detail=""):
    print("  ❌ " + msg)
    if detail:
        print("     " + str(detail)[:500])
    failed.append(msg)


TOOL_CHAT = [{"type": "function", "function": {
    "name": "read_file", "description": "读取一个文件的内容",
    "parameters": {"type": "object",
                   "properties": {"path": {"type": "string", "description": "文件路径"}},
                   "required": ["path"]}}}]
TOOL_RESP = [{"type": "function", "name": "read_file", "description": "读取一个文件的内容",
              "parameters": {"type": "object",
                             "properties": {"path": {"type": "string"}},
                             "required": ["path"]}}]

print("=== 冒烟测试: model=%s ===" % MODEL)

print("[1/5] 网关存活")
try:
    urllib.request.urlopen(GW + "/health/liveliness", timeout=10).read()
    ok("gateway up")
except Exception as e:
    no("gateway 未响应，先跑 docker compose up -d", e); sys.exit(1)

print("[2/5] 基础 chat completion")
d = call("/v1/chat/completions", {"model": MODEL, "max_tokens": 64,
         "messages": [{"role": "user", "content": "只回复两个字：正常"}]})
if d.get("error"):
    no("chat 失败", d["error"].get("message"))
else:
    print("  -> " + (d["choices"][0]["message"].get("content") or "")[:80])
    ok("chat 通")

print("[3/5] tool calling（关键项 — Codex 全靠它读写文件）")
d = call("/v1/chat/completions", {
    "model": MODEL, "max_tokens": 512, "tools": TOOL_CHAT, "tool_choice": "auto",
    "messages": [{"role": "user",
                  "content": "读取当前目录下 config.toml 的内容。必须调用工具，不要凭空回答。"}]})
if d.get("error"):
    no("chat+tools 请求失败", d["error"].get("message"))
else:
    tc = d["choices"][0]["message"].get("tool_calls") or []
    if not tc:
        no("无 tool_calls，模型只回了文本",
           d["choices"][0]["message"].get("content"))
    else:
        fn = tc[0]["function"]
        try:
            args = json.loads(fn["arguments"])
        except Exception:
            args = None
        print("  -> tool_calls[0]: %s(%s)" % (fn["name"], args))
        if fn["name"] == "read_file" and isinstance(args, dict) and "path" in args:
            ok("tool calling 正常（函数名与参数结构均合法）")
        else:
            no("tool call 结构不合法")

print("[4/5] 流式 + tool call 增量拼装")
raw = call("/v1/chat/completions", {
    "model": MODEL, "max_tokens": 512, "stream": True, "tools": TOOL_CHAT,
    "messages": [{"role": "user", "content": "读取 README.md。必须调用工具。"}]}, stream=True)
n = raw.count("tool_calls")
ok("流式 tool_calls 分片正常 (%d chunks)" % n) if n else no("流式下没有 tool_calls 分片", raw[:300])

print("[5/5] /v1/responses 桥接（Codex 实际走这条路，最关键）")
d = call("/v1/responses", {"model": MODEL, "tools": TOOL_RESP,
                           "input": "读取 config.toml。必须调用工具。"})
if d.get("error"):
    no("Responses 桥接失败 —— Codex 会跑不通", d["error"].get("message"))
else:
    calls = [o for o in d.get("output", []) if o.get("type") == "function_call"]
    if calls:
        print("  -> function_call: %s(%s)" % (calls[0].get("name"), calls[0].get("arguments")))
        ok("Responses→ChatCompletions 桥接 + 工具调用正常")
    else:
        types = [o.get("type") for o in d.get("output", [])]
        no("桥接通了但没产出 function_call，output types=%s" % types)

print("\n=== 通过 %d / 失败 %d ===" % (len(passed), len(failed)))
for f in failed:
    print("  失败项: " + f)
sys.exit(1 if failed else 0)
