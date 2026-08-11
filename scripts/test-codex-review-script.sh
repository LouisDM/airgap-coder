#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test -x "$ROOT/scripts/codex-review.sh"
output="$("$ROOT/scripts/codex-review.sh" --help)"

case "$output" in
  *"read-only"*"ephemeral"*"No API key"*) ;;
  *) echo "❌ review help does not describe its security boundary" >&2; exit 1 ;;
esac

grep -q '^\.codex-review/$' "$ROOT/.gitignore"
grep -q -- '--ignore-user-config' "$ROOT/scripts/codex-review.sh"
if grep -nE 'auth\.json|OPENAI_API_KEY=' "$ROOT/scripts/codex-review.sh"; then
  echo "❌ local review workflow must not copy auth or embed an API key" >&2
  exit 1
fi

if grep -qE -- '--dangerously-bypass-(approvals-and-sandbox|hook-trust)' "$ROOT/scripts/codex-review.sh"; then
  echo "❌ local review must not bypass the sandbox or hook trust" >&2
  exit 1
fi

if grep -qE -- '--(base|uncommitted).*(- <|< )' "$ROOT/scripts/codex-review.sh"; then
  echo "❌ Codex 0.145 review targets cannot be combined with a prompt argument" >&2
  exit 1
fi

echo "✅ local Codex review workflow is isolated from committed credentials"
