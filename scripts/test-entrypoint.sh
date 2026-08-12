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

# issue #50 / #52: the container runs Codex with danger-full-access, so a `.env`
# inside the mounted workspace is readable by one `cat`. #50 shipped a warning;
# #52 decided that is not enough for the users who actually step on it (they are
# following the documented happy path, and under non-interactive `codex exec` one
# stderr line drowns in model output). So: refuse to start, with an explicit
# escape hatch -- and, just as importantly, stay quiet when there is no `.env`:
# a check that always fires is not a check (same reasoning as `lc code` in #46).
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

# (1) `.env` in the workspace: non-zero exit, and Codex must not have been started.
printf 'KEY_INTRANET=must-not-be-printed\n' > "$WORK/ws/.env"
cp /dev/null "$WORK/args"
if (run_in_workspace exec "inspect the repository") > "$WORK/block.log" 2>&1; then
  echo "❌ a .env in the workspace must make the entrypoint exit non-zero" >&2
  cat "$WORK/block.log" >&2
  exit 1
fi
if [ -s "$WORK/args" ]; then
  echo "❌ the entrypoint refused but started codex anyway" >&2
  cat "$WORK/args" >&2
  exit 1
fi
grep -q "$WORK/ws/.env" "$WORK/block.log" || {
  echo "❌ the refusal does not name the offending file" >&2
  cat "$WORK/block.log" >&2
  exit 1
}
grep -q 'danger-full-access' "$WORK/block.log" || {
  echo "❌ the refusal does not say why it matters (full access session)" >&2
  exit 1
}
# The container has no "cd somewhere else" option -- the only thing the user can
# change is the mount, so that is what the message has to teach.
grep -q -- '-v "/path/to/your-project:/workspace"' "$WORK/block.log" || {
  echo "❌ the refusal does not show the correct mount syntax" >&2
  exit 1
}
grep -q 'AIRGAP_ALLOW_WORKSPACE_SECRETS=1' "$WORK/block.log" || {
  echo "❌ the refusal does not mention the escape hatch -- a hard stop with no" \
       "documented way out just makes people delete the check" >&2
  exit 1
}
# The message names the file; it must never read or echo its contents.
if grep -q 'must-not-be-printed' "$WORK/block.log"; then
  echo "❌ the refusal printed a value out of .env" >&2
  exit 1
fi

# (2) Escape hatch: starts normally *and still prints the warning*. The second
# half is the one that rots -- an override that goes quiet is just the old
# warning with one extra step (issue #52).
cp /dev/null "$WORK/args"
export AIRGAP_ALLOW_WORKSPACE_SECRETS=1
if ! (run_in_workspace exec "inspect the repository") \
    > "$WORK/allow.log" 2>&1; then
  echo "❌ AIRGAP_ALLOW_WORKSPACE_SECRETS=1 should let the session start" >&2
  cat "$WORK/allow.log" >&2
  exit 1
fi
expected="$(printf '%s\n' exec --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox 'inspect the repository')"
if [ "$(cat "$WORK/args")" != "$expected" ]; then
  echo "❌ the escape hatch altered the codex invocation" >&2
  cat "$WORK/args" >&2
  exit 1
fi
grep -q "$WORK/ws/.env" "$WORK/allow.log" || {
  echo "❌ the escape hatch silenced the warning -- it must still name the file" >&2
  cat "$WORK/allow.log" >&2
  exit 1
}
grep -q 'danger-full-access' "$WORK/allow.log" || {
  echo "❌ the escape hatch dropped the reason the warning matters" >&2
  exit 1
}
if grep -q 'must-not-be-printed' "$WORK/allow.log"; then
  echo "❌ the warning printed a value out of .env" >&2
  exit 1
fi
# Any value other than exactly "1" must not open the gate: a stray
# `AIRGAP_ALLOW_WORKSPACE_SECRETS=0` or `=false` reads as "off" to whoever wrote
# it, and silently meaning "on" is the worst possible failure for this check.
for val in 0 false ""; do
  cp /dev/null "$WORK/args"
  export AIRGAP_ALLOW_WORKSPACE_SECRETS="$val"
  if (run_in_workspace exec "x") > "$WORK/off.log" 2>&1; then
    echo "❌ AIRGAP_ALLOW_WORKSPACE_SECRETS='$val' must not open the gate" >&2
    cat "$WORK/off.log" >&2
    exit 1
  fi
done
unset AIRGAP_ALLOW_WORKSPACE_SECRETS

rm -f "$WORK/ws/.env"

echo "✅ entrypoint routes exec-only flags, passes version/help through without gateway config, validates required variables, and refuses to start with a .env in the workspace unless explicitly allowed"
