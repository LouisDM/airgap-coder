#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/fakebin" "$WORK/codex"

cp /dev/null "$WORK/args"
cat > "$WORK/fakebin/codex" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$ENTRYPOINT_ARGS"
EOF
chmod +x "$WORK/fakebin/codex"

run_entrypoint() {
  PATH="$WORK/fakebin:/usr/bin:/bin" \
  CODEX_HOME="$WORK/codex" \
  CONTEXT_WINDOW=8192 \
  MAX_OUTPUT_TOKENS=1024 \
  GATEWAY_URL=http://gateway.example.local:4000/v1 \
  GATEWAY_KEY=test-only \
  MODEL=mock-model \
  ENTRYPOINT_ARGS="$WORK/args" \
  /bin/bash "$ROOT/docker/entrypoint.sh" "$@"
}

run_entrypoint exec "inspect the repository"
expected="$(printf '%s\n' exec --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox 'inspect the repository')"
test "$(cat "$WORK/args")" = "$expected"

run_entrypoint --version
test "$(cat "$WORK/args")" = "--version"

grep -q 'base_url = "http://gateway.example.local:4000/v1"' "$WORK/codex/config.toml"
grep -q 'model = "mock-model"' "$WORK/codex/config.toml"

if PATH="$WORK/fakebin:/usr/bin:/bin" CODEX_HOME="$WORK/codex" \
  CONTEXT_WINDOW=8192 MAX_OUTPUT_TOKENS=1024 GATEWAY_KEY=test-only MODEL=mock-model \
  ENTRYPOINT_ARGS="$WORK/args" /bin/bash "$ROOT/docker/entrypoint.sh" exec test \
  > "$WORK/error" 2>&1; then
  echo "❌ missing GATEWAY_URL should fail" >&2
  exit 1
fi
grep -q 'GATEWAY_URL' "$WORK/error"

echo "✅ entrypoint routes exec-only flags and validates required variables"
