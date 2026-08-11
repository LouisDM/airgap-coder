#!/usr/bin/env bash
# ci-exempt: 端到端测试，需要活的 LiteLLM 网关和真实模型 API Key，
# ci-exempt: CI 环境两者都没有。改动本脚本时请本地手工验证。
# 端到端：让 Codex 真的在沙箱目录里改代码，验证 agent 循环闭合。
# 用法: ./scripts/test-codex.sh <profile>   例: ./scripts/test-codex.sh qwen
set -uo pipefail

PROFILE="${1:-kimi}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; . "$ROOT/.env"; set +a
export CODEX_HOME="$ROOT/codex"

# Codex 对不存在的 profile 不报错，会静默回落到 config.toml 的默认 model，
# 导致你以为在测 A 其实在测 B。这里显式挡掉。
if [ ! -f "$CODEX_HOME/${PROFILE}.config.toml" ]; then
  # 一个 profile 都没生成时 `ls` 什么都不输出，xargs 会拿空输入去调 basename，
  # 于是真正的那句提示前面先蹦出一行 "basename: missing operand"——读的人会
  # 以为脚本自己坏了。改成用 for 展开，没匹配到就是空列表。
  avail=""
  for f in "$CODEX_HOME"/*.config.toml; do
    [ -e "$f" ] || continue
    n="$(basename "$f")"
    avail="$avail ${n%.config.toml}"
  done
  if [ -n "$avail" ]; then
    echo "❌ profile '${PROFILE}' 不存在。可用:$avail"
  else
    echo "❌ profile '${PROFILE}' 不存在，而且 $CODEX_HOME 下一个 profile 都没有。先跑 \`lc sync\`"
  fi
  exit 2
fi

WORK="$ROOT/.smoke/$PROFILE"
rm -rf "$WORK"; mkdir -p "$WORK"
cat > "$WORK/calc.py" <<'PY'
def add(a, b):
    return a - b        # BUG: 应该是加法


def mul(a, b):
    return a * b
PY

echo "=== 端到端测试: profile=${PROFILE} ==="
echo "任务：修复 calc.py 里的 bug 并新建 test_calc.py"
echo

cd "$WORK"
codex exec --profile "$PROFILE" --skip-git-repo-check \
  "修复 calc.py 中 add 函数的 bug（它写成了减法），然后新建 test_calc.py，用 assert 覆盖 add 和 mul 各一个用例。直接改文件，不要只输出建议。" \
  2>&1 | tail -40

echo
echo "--- 结果校验 ---"
FAIL=0
grep -q 'a + b' calc.py && echo "  ✅ calc.py 的 bug 已修复" || { echo "  ❌ calc.py 未被修改"; FAIL=1; }
[ -f test_calc.py ] && echo "  ✅ test_calc.py 已创建" || { echo "  ❌ test_calc.py 未创建"; FAIL=1; }
if [ -f test_calc.py ]; then
  python3 test_calc.py && echo "  ✅ 生成的测试可运行且通过" || { echo "  ❌ 生成的测试跑不过"; FAIL=1; }
fi
echo
[ "$FAIL" -eq 0 ] && echo "=== 端到端通过：该模型可以做 Codex 底座 ===" \
                  || echo "=== 端到端失败：见上方 ==="
exit $FAIL
