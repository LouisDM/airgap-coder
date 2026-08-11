#!/usr/bin/env python3
"""Deterministic OpenAI Chat Completions fixture for bridge tests."""
from __future__ import print_function

import argparse
import json
import time
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    server_version = "airgap-coder-mock/1"

    def log_message(self, fmt, *args):
        print("mock: " + (fmt % args), flush=True)

    def send_json(self, status, payload):
        raw = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        if self.path == "/healthz":
            self.send_json(200, {"status": "ok"})
            return
        self.send_json(404, {"error": {"message": "not found"}})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        try:
            body = json.loads(self.rfile.read(length).decode("utf-8"))
        except (ValueError, UnicodeDecodeError) as exc:
            self.send_json(400, {"error": {"message": str(exc)}})
            return

        print("mock-request path=%s body=%s" %
              (self.path, json.dumps(body, sort_keys=True)), flush=True)
        if self.path != "/v1/chat/completions":
            self.send_json(404, {"error": {"message": "expected chat completions"}})
            return

        tools = body.get("tools") or []
        if tools:
            function = tools[0].get("function", {})
            name = function.get("name") or "read_file"
            message = {
                "role": "assistant",
                "content": None,
                "tool_calls": [{
                    "id": "call_airgap_fixture",
                    "type": "function",
                    "function": {
                        "name": name,
                        "arguments": json.dumps({"path": "README.md"}),
                    },
                }],
            }
            finish_reason = "tool_calls"
        else:
            message = {"role": "assistant", "content": "mock-ok"}
            finish_reason = "stop"

        self.send_json(200, {
            "id": "chatcmpl-airgap-fixture",
            "object": "chat.completion",
            "created": int(time.time()),
            "model": body.get("model", "mock-model"),
            "choices": [{
                "index": 0,
                "message": message,
                "finish_reason": finish_reason,
            }],
            "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
        })


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8080)
    args = parser.parse_args()
    print("mock-listening port=%d" % args.port, flush=True)
    HTTPServer(("0.0.0.0", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
