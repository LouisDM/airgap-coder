#!/usr/bin/env python3
"""Assert that LiteLLM exposes a Responses-compatible function call."""
from __future__ import print_function

import json
import sys
import urllib.request


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_bridge_client.py <gateway-url>")
    payload = {
        "model": "mock-model",
        "input": "Read README.md. You must call the tool.",
        "tools": [{
            "type": "function",
            "name": "read_file",
            "description": "Read a repository file",
            "parameters": {
                "type": "object",
                "properties": {"path": {"type": "string"}},
                "required": ["path"],
                "additionalProperties": False,
            },
        }],
    }
    request = urllib.request.Request(
        sys.argv[1].rstrip("/") + "/v1/responses",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": "Bearer sk-airgap-test-master",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        data = json.loads(response.read().decode("utf-8"))

    calls = [item for item in data.get("output", [])
             if item.get("type") == "function_call"]
    if not calls:
        raise SystemExit("Responses output has no function_call: %s" %
                         json.dumps(data, sort_keys=True))
    call = calls[0]
    if call.get("name") != "read_file":
        raise SystemExit("unexpected function name: %r" % call.get("name"))
    arguments = json.loads(call.get("arguments", "{}"))
    if arguments != {"path": "README.md"}:
        raise SystemExit("unexpected function arguments: %r" % arguments)
    print("✅ Responses -> Chat Completions -> function_call bridge passed")


if __name__ == "__main__":
    main()
