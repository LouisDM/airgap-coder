#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="$(sed -nE 's/^[[:space:]]*image:[[:space:]]*([^[:space:]]+).*/\1/p' "$ROOT/docker-compose.yml" | head -1)"
RUN_ID="${GITHUB_RUN_ID:-$$}-${RANDOM}"
NETWORK="airgap-bridge-$RUN_ID"
MOCK="airgap-mock-$RUN_ID"
GATEWAY="airgap-litellm-$RUN_ID"

cleanup() {
  docker rm -f "$GATEWAY" "$MOCK" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
}
trap cleanup EXIT

test -n "$IMAGE"
docker network create "$NETWORK" >/dev/null

docker run -d --name "$MOCK" --network "$NETWORK" \
  --network-alias mock-backend \
  --entrypoint python \
  -v "$ROOT/scripts/mock_chat_server.py:/tests/mock_chat_server.py:ro" \
  "$IMAGE" /tests/mock_chat_server.py --port 8080 >/dev/null

docker run -d --name "$GATEWAY" --network "$NETWORK" \
  -v "$ROOT/tests/fixtures/litellm-mock.yaml:/app/config.yaml:ro" \
  -v "$ROOT/scripts/test_bridge_client.py:/tests/test_bridge_client.py:ro" \
  "$IMAGE" --config /app/config.yaml --port 4000 --num_workers 1 >/dev/null

ready=0
for _ in $(seq 1 60); do
  if docker exec "$GATEWAY" python -c \
    'import urllib.request; urllib.request.urlopen("http://127.0.0.1:4000/health/liveliness", timeout=2).read()' \
    >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done

if [ "$ready" -ne 1 ]; then
  docker logs "$MOCK" || true
  docker logs "$GATEWAY" || true
  echo "❌ LiteLLM did not become healthy" >&2
  exit 1
fi

docker exec "$GATEWAY" python /tests/test_bridge_client.py http://127.0.0.1:4000

logs="$(docker logs "$MOCK" 2>&1)"
case "$logs" in
  *"mock-request path=/v1/chat/completions"*) ;;
  *)
    echo "$logs"
    echo "❌ mock backend did not receive /v1/chat/completions" >&2
    exit 1
    ;;
esac

echo "✅ mock backend observed Chat Completions request"
