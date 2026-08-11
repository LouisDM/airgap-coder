#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="base"
BASE="main"

usage() {
  cat <<'EOF'
Usage: scripts/codex-review.sh [--base BRANCH | --uncommitted]

Run a read-only, ephemeral Codex review using the current local Codex login.
The final report is saved under ignored .codex-review/. No API key is copied,
printed, or uploaded by this script.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --base)
      test "$#" -ge 2 || { echo "--base requires a branch" >&2; exit 2; }
      MODE="base"
      BASE="$2"
      shift 2
      ;;
    --uncommitted)
      MODE="uncommitted"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

command -v codex >/dev/null 2>&1 || {
  echo "Codex CLI is not installed. See https://developers.openai.com/codex/cli" >&2
  exit 1
}

if ! codex login status >/dev/null 2>&1; then
  echo "Codex is not signed in. Run 'codex login' and choose ChatGPT sign-in." >&2
  exit 1
fi

mkdir -p "$ROOT/.codex-review"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
output="$ROOT/.codex-review/review-$stamp.md"

common=(
  --ephemeral
  --ignore-user-config
  -c 'sandbox_mode="read-only"'
  -c 'approval_policy="never"'
  -o "$output"
)

cd "$ROOT"
if [ "$MODE" = "uncommitted" ]; then
  codex exec review "${common[@]}" --uncommitted
else
  git rev-parse --verify "$BASE" >/dev/null 2>&1 || {
    echo "Base branch not found: $BASE" >&2
    exit 1
  }
  codex exec review "${common[@]}" --base "$BASE"
fi

echo "Codex review saved to: $output"
