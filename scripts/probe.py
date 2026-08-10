#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""tool calling 探测的共享定义：请求体、断言、失败提示。

`bin/lc doctor`（直连上游）和 `scripts/smoke.py`（打网关）用的是同一套判据，
所以判据放在这里，两边 import。分开写两份的结果是「doctor 说没问题、
test 说有问题」，而这个项目里最常见的失败恰恰就是 tool calling 静默失效。

纯数据 + 纯函数，import 它不产生任何副作用（smoke.py 反过来不行——它一被
import 就会读 .env 并跑完 5 步）。零第三方依赖。
"""

# 探测用的工具定义。故意选一个最普通的单参数函数：
# 能不能调起来只反映服务端的工具解析是否开启，不考验模型的推理能力。
TOOL_CHAT = [{"type": "function", "function": {
    "name": "read_file", "description": "读取一个文件的内容",
    "parameters": {"type": "object",
                   "properties": {"path": {"type": "string", "description": "文件路径"}},
                   "required": ["path"]}}}]

TOOL_RESP = [{"type": "function", "name": "read_file", "description": "读取一个文件的内容",
              "parameters": {"type": "object",
                             "properties": {"path": {"type": "string"}},
                             "required": ["path"]}}]

PROBE_PROMPT = "读取当前目录下 config.toml 的内容。必须调用工具，不要凭空回答。"

# 一个完整的 tool_calls 结构装不进几十个 token。给小了会被截断，
# 看起来就像「模型没调工具」——这是误报，不是失败。
PROBE_MAX_TOKENS = 512


def chat_payload(model, params=None):
    """构造带 tools 的 chat/completions 请求体。

    params 是该上游在 registry 里登记的额外参数（如关思考模式的开关）。
    直连探测必须带上它，否则打出去的请求和网关实际发出的请求不是同一个配置，
    探测结论迁移不到真实链路上。
    """
    body = {"model": model, "max_tokens": PROBE_MAX_TOKENS,
            "tools": TOOL_CHAT, "tool_choice": "auto",
            "messages": [{"role": "user", "content": PROBE_PROMPT}]}
    for k, v in sorted((params or {}).items()):
        body[k] = v
    return body


# 每种失败的成因在这个项目里都是高度确定的，结论写死在这儿，
# 省得每个用户重新踩一遍。key 对应下面的断言分支与 smoke.py 的 5 步。
HINTS = {
    "gateway_down":
        "先 `lc up` 起网关，再 `lc status` 确认 4000 端口存活；"
        "起不来就看 `lc logs`",
    "chat_failed":
        "上游地址或密钥不对，也可能是本机代理劫持了内网地址（Clash tun 模式会劫 DNS）。"
        "核对 .env 里的 KEY_*（地址要到 /v1 为止），并确认 HTTP(S)_PROXY 没把内网域名带走"
        "——给内网域名加 DIRECT 规则或设 NO_PROXY",
    "tools_request_failed":
        "上游拒绝了带 tools 的请求，多半是模型服务本身不支持 function calling。"
        "vLLM 需要 `--enable-auto-tool-choice --tool-call-parser hermes`",
    "no_tool_calls":
        "服务端没开工具解析：vLLM 启动参数补上 "
        "`--enable-auto-tool-choice --tool-call-parser hermes`"
        "（parser 按模型 family 选，Qwen 系用 hermes，以你的 vLLM 版本文档为准）",
    "bad_tool_call":
        "工具解析开了但 parser 选错了 —— 模型吐的格式和 parser 对不上。"
        "换成与模型 family 匹配的 `--tool-call-parser` 再试，这跟「没开」不是一回事",
    "bad_response":
        "上游返回了 200，但 body 不是合法的 chat/completions 结构。"
        "核对地址是不是指到了别的服务（比如少写了 /v1，或指向了网关自身）",
    "no_stream_chunks":
        "若第 3 步也挂，同因，先修第 3 步；若第 3 步过了只有这里挂，"
        "指向上游的流式实现或 parser 的增量拼装，建议升级 vLLM / SGLang 再看",
    "bridge_failed":
        "网关多半缺 `use_chat_completions_api: true`，`/v1/responses` 被原样透传给上游，"
        "而上游没这个端点。跑 `lc sync` 重新生成 litellm/config.yaml，再 `lc up`",
    "bridge_no_function_call":
        "桥接本身是通的，是模型的 tool calling 能力不够。"
        "考虑换权重（如 Qwen3-Coder 系），或退到 Aider（纯文本 diff）/ OpenCode",
    "thinking_on":
        "关思考模式的参数名两家不同，填错会静默失效：vLLM / SGLang 用 "
        "`chat_template_kwargs.enable_thinking`，托管服务（百炼/Ark）用顶层 "
        "`enable_thinking`。用 `lc add` 覆盖同名上游可以重选后端类型",
}

# 断言失败时的一句话结论，和 HINTS 分开：前者说「是什么」，后者说「怎么修」。
TITLES = {
    "tools_request_failed": "上游拒绝了带 tools 的请求",
    "no_tool_calls": "tool calling 未生效 —— 返回了文本而非 tool_calls",
    "bad_tool_call": "tool call 结构不合法 —— parser 可能选错了",
    "bad_response": "响应结构无法解析",
}


def hint(key):
    return HINTS.get(key, key)


def title(key):
    return TITLES.get(key, key or "未知失败")


def _message(resp):
    try:
        return resp["choices"][0]["message"] or {}
    except (KeyError, IndexError, TypeError):
        return None


def check_tool_call(resp):
    """判定一个 chat/completions 响应里的 tool calling 是否真的生效。

    返回 (ok, key, detail)：ok 为 True 时 key 是 None，detail 是可打印的调用摘要；
    ok 为 False 时 key 是 HINTS / TITLES 的键，detail 是给用户看的现场信息。
    """
    import json

    if not isinstance(resp, dict):
        return False, "bad_response", str(resp)[:200]
    # 有的网关/推理框架出错时照样返回 200，把错误塞在 body 里。
    # 只看 HTTP 状态码会把这种情况判成「可达」。
    if resp.get("error"):
        e = resp["error"]
        detail = e.get("message") if isinstance(e, dict) else str(e)
        return False, "tools_request_failed", detail
    msg = _message(resp)
    if msg is None:
        return False, "bad_response", json.dumps(resp, ensure_ascii=False)[:200]

    tc = msg.get("tool_calls") or []
    if not tc:
        return False, "no_tool_calls", msg.get("content") or "(空响应)"

    fn = (tc[0] or {}).get("function") or {}
    try:
        args = json.loads(fn.get("arguments") or "")
    except (ValueError, TypeError):
        args = None
    summary = "%s(%s)" % (fn.get("name"), args)
    if fn.get("name") == "read_file" and isinstance(args, dict) and "path" in args:
        return True, None, summary
    return False, "bad_tool_call", summary


def reasoning_leak(resp):
    """思考模式是否还开着。返回一段可打印的现场证据，没有则返回 None。

    <think> 块会混进 content 干扰 tool call 解析，所以即便工具调用这次侥幸
    过了，也值得提示。判定不成立时返回 None，不要猜。
    """
    msg = _message(resp)
    if not msg:
        return None
    rc = msg.get("reasoning_content")
    if rc:
        return "reasoning_content: " + str(rc)[:80]
    content = msg.get("content") or ""
    if "<think>" in content:
        return "content 里含 <think> 块"
    return None
