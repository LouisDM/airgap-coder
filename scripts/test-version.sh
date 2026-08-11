#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
expected="$(tr -d '[:space:]' < "$ROOT/VERSION")"

test -n "$expected"
test "$(NO_COLOR=1 python3 "$ROOT/bin/lc" --version)" = "airgap-coder $expected"
test "$(NO_COLOR=1 python3 "$ROOT/bin/lc" -V)" = "airgap-coder $expected"
test "$(NO_COLOR=1 python3 "$ROOT/bin/lc" version)" = "airgap-coder $expected"

grep -q "ARG CODEX_VERSION=0.145.0" "$ROOT/docker/Dockerfile"

echo "✅ version: $expected; Codex baseline: 0.145.0"
