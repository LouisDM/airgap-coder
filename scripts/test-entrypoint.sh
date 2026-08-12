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

# issue #29: version and help must not require gateway configuration. These runs
# deliberately unset GATEWAY_URL / GATEWAY_KEY / MODEL -- and CONTEXT_WINDOW /
# MAX_OUTPUT_TOKENS as well. Under `set -u` the config heredoc expands those two,
# so this also pins that routing happens *before* config generation: if the
# passthrough is removed, the run fails instead of silently writing a stub config.
mkdir -p "$WORK/bare"
run_bare() {
  PATH="$WORK/fakebin:/usr/bin:/bin" \
  CODEX_HOME="$WORK/bare" \
  ENTRYPOINT_ARGS="$WORK/args" \
  /bin/bash "$ROOT/docker/entrypoint.sh" "$@"
}

for flag in --version -V --help -h; do
  cp /dev/null "$WORK/args"
  if ! run_bare "$flag" > "$WORK/bare.log" 2>&1; then
    echo "❌ $flag should not require gateway configuration" >&2
    cat "$WORK/bare.log" >&2
    exit 1
  fi
  if [ "$(cat "$WORK/args")" != "$flag" ]; then
    echo "❌ $flag was not passed through to codex verbatim" >&2
    exit 1
  fi
done

# The passthrough branch must not leave a config.toml behind: without the gateway
# variables it could only be a broken one, and a broken config that exists is
# worse than none -- the next run with real variables overwrites it, but a bind
# mounted CODEX_HOME would keep it.
if [ -e "$WORK/bare/config.toml" ]; then
  echo "❌ passthrough branch wrote a config.toml without gateway variables" >&2
  exit 1
fi

# issue #50: the container runs Codex with danger-full-access, so a `.env` inside
# the mounted workspace is readable by one `cat`. Warn on stderr, never block --
# and, just as importantly, stay quiet when there is no `.env`: a warning that
# always fires is not a warning (same reasoning as the `lc code` check in #46).
mkdir -p "$WORK/ws"
run_in_workspace() {
  cd "$WORK/ws" || exit 1
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

cp /dev/null "$WORK/args"
rm -f "$WORK/ws/.env"
(run_in_workspace exec "inspect the repository") > "$WORK/clean.log" 2>&1
if grep -q '\.env' "$WORK/clean.log"; then
  echo "❌ workspace warning fired without a .env in the workspace" >&2
  cat "$WORK/clean.log" >&2
  exit 1
fi

printf 'KEY_INTRANET=must-not-be-printed\n' > "$WORK/ws/.env"
cp /dev/null "$WORK/args"
(run_in_workspace exec "inspect the repository") > "$WORK/warn.log" 2>&1
grep -q "$WORK/ws/.env" "$WORK/warn.log" || {
  echo "❌ .env in the workspace did not produce a warning" >&2
  cat "$WORK/warn.log" >&2
  exit 1
}
grep -q 'danger-full-access' "$WORK/warn.log" || {
  echo "❌ the warning does not say why it matters (full access session)" >&2
  exit 1
}
# The warning names the file; it must never read or echo its contents.
if grep -q 'must-not-be-printed' "$WORK/warn.log"; then
  echo "❌ the warning printed a value out of .env" >&2
  exit 1
fi
# Warn, do not block: codex still runs with the exact same arguments.
expected="$(printf '%s\n' exec --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox 'inspect the repository')"
if [ "$(cat "$WORK/args")" != "$expected" ]; then
  echo "❌ the warning blocked or altered the codex invocation" >&2
  exit 1
fi

echo "✅ entrypoint routes exec-only flags, passes version/help through without gateway config, validates required variables, and warns about a .env in the workspace"
