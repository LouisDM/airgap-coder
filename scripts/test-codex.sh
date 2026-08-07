#!/usr/bin/env bash
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
  echo "❌ profile '${PROFILE}' 不存在。可用: $(ls "$CODEX_HOME"/*.config.toml 2>/dev/null | xargs -n1 basename | sed 's/\.config\.toml//' | tr '\n' ' ')"
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
