#!/usr/bin/env bash
# 版本号一致性：VERSION 是唯一真源，凡是「本项目的版本」都必须由它推导。
# Codex 版本是另一件事（底座的版本），两者不许混用——混用过一次就是 issue #36：
# 镜像 tag 和离线包名当时用的是 Codex 版本，于是本项目连续多次发布产生的镜像
# 全都叫 airgap-coder:0.145.0，内网侧 docker load 新的直接覆盖旧的。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
expected="$(tr -d '[:space:]' < "$ROOT/VERSION")"

test -n "$expected"
test "$(NO_COLOR=1 python3 "$ROOT/bin/lc" --version)" = "airgap-coder $expected"
test "$(NO_COLOR=1 python3 "$ROOT/bin/lc" -V)" = "airgap-coder $expected"
test "$(NO_COLOR=1 python3 "$ROOT/bin/lc" version)" = "airgap-coder $expected"

grep -q "ARG CODEX_VERSION=0.145.0" "$ROOT/docker/Dockerfile"

# ── 镜像 tag 由 VERSION 推导（issue #36） ─────────────────────────────────
# lc export 推导 tag 的那行代码单独成了 _dev_image_ref()，直接问它，不去解析源码。
tag="$(NO_COLOR=1 python3 - "$ROOT/bin/lc" <<'PY'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("lc", sys.argv[1])
spec = importlib.util.spec_from_file_location("lc", sys.argv[1], loader=loader)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
print(mod._dev_image_ref())
PY
)"
test "$tag" = "airgap-coder:$expected" || {
  echo "::error::lc export 推导的镜像 tag 是 $tag，应当是 airgap-coder:$expected"
  exit 1
}
# 反向再查一次：tag 里不许出现 Codex 版本。上面那条在两个版本号偶然相等时
# 会假通过，而「用错了哪个版本号」正是这个 issue 的全部内容。
case "$tag" in
  *0.145.0*) echo "::error::镜像 tag 用的是 Codex 版本，不是本项目版本"; exit 1 ;;
esac

# Dockerfile 的 APP_VERSION 只喂给 OCI label，但它是第二个写着本项目版本号的
# 地方。漂了之后 `docker inspect` 会报一个和 tag 不符的版本——比没有 label 更坏。
grep -q "^ARG APP_VERSION=$expected\$" "$ROOT/docker/Dockerfile" || {
  echo "::error::docker/Dockerfile 的 ARG APP_VERSION 与 VERSION($expected) 不一致"
  exit 1
}
grep -q 'org.opencontainers.image.version="${APP_VERSION}"' "$ROOT/docker/Dockerfile" || {
  echo "::error::镜像缺 org.opencontainers.image.version label"; exit 1
}
grep -q 'io.airgap-coder.codex-version="${CODEX_VERSION}"' "$ROOT/docker/Dockerfile" || {
  echo "::error::Codex 版本从 tag 里移走了，必须有 label 记着，否则内网侧查不到"
  exit 1
}

# 文档里那条构建命令的 tag 也必须是同一个：不一致的话，读者照文档构建出来的
# 镜像 lc export 不认，而它报的是「本机没有镜像 airgap-coder:X」——很难联想到
# 根因是文档和代码各说一个 tag。
bad="$(grep -rho "airgap-coder:[0-9][^ \"']*" \
  "$ROOT/docker/Dockerfile" "$ROOT/docs/offline-deployment.md" \
  "$ROOT/README.md" "$ROOT/README.zh-CN.md" | sort -u \
  | grep -v "^airgap-coder:$expected\$" || true)"
test -z "$bad" || {
  echo "::error::文档里的镜像 tag 与 VERSION($expected) 不一致: $bad"
  exit 1
}

echo "✅ version: $expected; Codex baseline: 0.145.0; dev image: $tag"
