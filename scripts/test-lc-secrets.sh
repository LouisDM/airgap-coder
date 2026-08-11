#!/usr/bin/env bash
# 钉住「机密只进 .env，registry.json 里只有变量名」这个不变量（issue #12 第一梯队）。
#
# 覆盖的是 lc init / add / rm / migrate 这四个会写凭证文件的命令。它们之前零断言，
# 而写坏了的后果不是报错而是静默泄漏：registry.json 是**可提交**的文件（见
# .gitignore 里的说明），一旦 lc 把 API Key、内网地址或某个 header 的值直接写进
# 它而不是写成 KEY_* 变量名，下一次 git push 就把凭证送出去了。
# ci.yml 里那条 registry 扫描只看仓库里现存的那份 registry.json，管不到
# 「lc 新写出来的 registry 长什么样」——这个脚本补的就是这段。
#
# 顺带钉住 rm 的孤儿密钥：删上游时对应的 KEY_* / KEY_*_BASE / header 变量必须
# 一起从 .env 里清掉，否则密钥会在文件里留到下一次泄漏。
#
# 用法: bash scripts/test-lc-secrets.sh     （零依赖，只用 Python 标准库）
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# lc 的 ROOT 由自身路径推导（__file__ 的上两级），所以只要把 bin/lc 复制到临时
# 目录里，它读写的 registry.json / .env / litellm/ / codex/ 就都落在那里，
# 绝不碰开发机上真实的配置。这也是 test-doctor-probe.sh / test-export.sh 的做法。
WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

SRC="$WORK/repo"
mkdir -p "$SRC/bin"
cp "$REPO/bin/lc" "$SRC/bin/lc"
cp "$REPO/registry.example.json" "$SRC/registry.example.json"
LC=("python3" "$SRC/bin/lc")

# 哨兵值运行时现生成，不写死字面量：这个脚本本身也是仓库里的源码，写死的字面量
# 会让「按值搜」的断言被脚本自己的内容误触发（test-export.sh 踩过这个坑）。
CANARY_KEY="lc-key-canary-$$-${RANDOM}${RANDOM}"
CANARY_HDR="lc-hdr-canary-$$-${RANDOM}${RANDOM}"
CANARY_KEY2="lc-key2-canary-$$-${RANDOM}${RANDOM}"
HOSTNAME_CANARY="vllm-canary-$$.your-intranet.local"

fails=0
pass() { echo "  ✅ $1"; }
fail() { echo "  ❌ $1"; echo "::error::$1"; fails=$((fails + 1)); }

have()   { grep -qF -e "$2" "$1"; }          # have <文件> <字符串>
assert() { if have "$2" "$3"; then pass "$1"; else fail "$1"; fi; }
refute() { if have "$2" "$3"; then fail "$1"; else pass "$1"; fi; }

run() {  # run <喂给 stdin 的答案文件> <日志> <lc 参数...>
  local answers="$1" log="$2"; shift 2
  if ! NO_COLOR=1 "${LC[@]}" "$@" < "$answers" > "$log" 2>&1; then
    cat "$log"
    echo "::error::lc $* 执行失败"
    exit 1
  fi
}

# ─────────────────────────────────────────────────────────────────────────
echo "[1] lc add：密钥、地址、header 值一律只进 .env"
# 答案顺序对应 _add_one 的提问：名称 / Base URL / 模型 ID / API Key /
# 上下文（空=默认）/ 最大输出（空=默认）/ 后端类型 / 要自定义头吗 /
# 头名 / 头值 / 头名（空=结束）
cat > "$WORK/a1" <<EOF
acme
http://$HOSTNAME_CANARY:8000/v1
Qwen/Qwen3-32B
$CANARY_KEY


1
y
User-Agent
$CANARY_HDR

EOF
run "$WORK/a1" "$WORK/log1" add
cat "$WORK/log1"

REG="$SRC/registry.json"
ENVF="$SRC/.env"
test -f "$REG"  || { fail "lc add 没有写出 registry.json"; }
test -f "$ENVF" || { fail "lc add 没有写出 .env"; }

# 核心断言：registry.json 里搜不到任何一个机密值
refute "registry.json 里没有 API Key 的值"        "$REG" "$CANARY_KEY"
refute "registry.json 里没有 HTTP 头的值"          "$REG" "$CANARY_HDR"
refute "registry.json 里没有内网主机名"            "$REG" "$HOSTNAME_CANARY"
if grep -qE 'https?://' "$REG"; then
  fail "registry.json 里出现了 URL —— 地址应该只在 .env 里"
else
  pass "registry.json 里没有任何 URL"
fi
# header 的值必须是 KEY_*_HEADER_* 变量名。这是 issue #4 的成果，
# 在此之前没有任何东西防止它回归成明文。
assert "registry.json 里 header 存的是变量名" "$REG" '"User-Agent": "KEY_ACME_HEADER_USER_AGENT"'

# 反面：机密确实进了 .env，而且变量名符合约定
assert ".env 里有 API Key"        "$ENVF" "KEY_ACME=$CANARY_KEY"
assert ".env 里有 Base URL"       "$ENVF" "KEY_ACME_BASE=http://$HOSTNAME_CANARY:8000/v1"
assert ".env 里有 HTTP 头的值"     "$ENVF" "KEY_ACME_HEADER_USER_AGENT=$CANARY_HDR"

MODE="$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))[-3:])' "$ENVF")"
if [ "$MODE" = "600" ]; then
  pass ".env 权限是 0600（同机其它用户读不到密钥）"
else
  fail ".env 权限是 0$MODE，应当是 0600"
fi

# 生成的网关配置必须走 os.environ/ 引用，而不是把值内联进 yaml
CFG="$SRC/litellm/config.yaml"
assert "config.yaml 里 header 走 os.environ/ 引用" "$CFG" "User-Agent: os.environ/KEY_ACME_HEADER_USER_AGENT"
refute "config.yaml 里没有 header 的明文值"        "$CFG" "$CANARY_HDR"
refute "config.yaml 里没有 API Key 的明文值"       "$CFG" "$CANARY_KEY"
refute "config.yaml 里没有内网主机名"              "$CFG" "$HOSTNAME_CANARY"

# ─────────────────────────────────────────────────────────────────────────
echo "[2] lc rm：删上游要把对应的密钥一并清掉，不留孤儿"
cat > "$WORK/a2" <<EOF
beta
http://beta-$HOSTNAME_CANARY:8000/v1
Qwen/Qwen3-8B
$CANARY_KEY2


3
n
EOF
run "$WORK/a2" "$WORK/log2" add
run /dev/null "$WORK/log3" rm acme
cat "$WORK/log3"

refute ".env 里 KEY_ACME 已删除"                    "$ENVF" "KEY_ACME="
refute ".env 里 KEY_ACME_BASE 已删除"               "$ENVF" "KEY_ACME_BASE="
refute ".env 里 header 变量已删除（不留孤儿密钥）"   "$ENVF" "KEY_ACME_HEADER_USER_AGENT"
# 按变量名查不够——真正要保证的是那个值不再留在文件里
refute ".env 里搜不到被删上游的 API Key 值"          "$ENVF" "$CANARY_KEY"
refute ".env 里搜不到被删上游的 header 值"           "$ENVF" "$CANARY_HDR"
# 别把别人的密钥一起删了
assert ".env 里其它上游的密钥没被误删"               "$ENVF" "KEY_BETA=$CANARY_KEY2"
assert "默认上游回落到仅剩的那个"                    "$REG" '"default": "beta"'
refute "registry.json 里 acme 已删除"               "$REG" '"acme"'

# ─────────────────────────────────────────────────────────────────────────
echo "[3] lc init：已有 registry.json 时只补 .env，不重问也不改结构参数"
# 团队场景：registry.json 随仓库下发，新人只填自己的地址和密钥。
# 如果 init 把结构参数（模型 ID / 上下文窗口 / 关思考模式的参数名）也重问一遍
# 或者覆盖掉，新人就得重新踩一遍这些坑——README 承诺过不会。
rm -f "$SRC/.env" "$REG"
python3 - "$SRC/registry.example.json" "$REG" <<'PY'
import json, sys
reg = json.load(open(sys.argv[1], encoding="utf-8"))
reg.pop("_comment", None)
# 加一个带 header 的上游，把 _fill_secrets 里 header 那条分支也走到
reg["upstreams"]["intranet"]["headers"] = {"User-Agent": "KEY_INTRANET_HEADER_USER_AGENT"}
json.dump(reg, open(sys.argv[2], "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY
cp "$REG" "$WORK/reg-before.json"

# 答案顺序：网关端口 / Base URL / API Key / header 值 / 再加一个吗
# 端口特意答一个非 4000 的值：init 唯一会问的这个配置项必须真的生效，而且只
# 生效在一个地方（issue #40）。答 4000 的话下面两条断言都会假通过。
cat > "$WORK/a3" <<EOF
4137
http://$HOSTNAME_CANARY:8000/v1
$CANARY_KEY
$CANARY_HDR
n
EOF
run "$WORK/a3" "$WORK/log4" init
cat "$WORK/log4"

assert "init 认出了已有 registry 并说明只补 .env" "$WORK/log4" "结构参数直接沿用"
if python3 - "$WORK/reg-before.json" "$REG" <<'PY'
import json, sys
a = json.load(open(sys.argv[1], encoding="utf-8"))["upstreams"]
b = json.load(open(sys.argv[2], encoding="utf-8"))["upstreams"]
if a == b:
    sys.exit(0)
print("  before: %s" % json.dumps(a, ensure_ascii=False, sort_keys=True))
print("  after : %s" % json.dumps(b, ensure_ascii=False, sort_keys=True))
sys.exit(1)
PY
then
  pass "已有上游的结构参数一字未改"
else
  fail "init 改动了已有上游的结构参数（模型 ID / 上下文窗口 / params 应当沿用）"
fi

# 网关端口：registry 是唯一真源，.env 里一行都不许有（issue #40）。
# 「让 sync 把端口同步进 .env」的实现也能让端口生效，但那是两个源保持同步，
# 手改 .env 之后照样漂移；这条钉的是「源被减掉了」，那种实现会让它变红。
assert "init 问来的端口写进了 registry"        "$REG" '"gateway_port": 4137'
refute ".env 里没有 GATEWAY_PORT（端口不走 .env）" "$ENVF" "GATEWAY_PORT"
assert ".env 补上了 Base URL"   "$ENVF" "KEY_INTRANET_BASE=http://$HOSTNAME_CANARY:8000/v1"
assert ".env 补上了 API Key"    "$ENVF" "KEY_INTRANET=$CANARY_KEY"
assert ".env 补上了 header 值"  "$ENVF" "KEY_INTRANET_HEADER_USER_AGENT=$CANARY_HDR"
refute "registry.json 仍然不含任何机密" "$REG" "$CANARY_KEY"
refute "registry.json 仍然不含内网主机名" "$REG" "$HOSTNAME_CANARY"
# init 会随机生成网关 master key；它是凭证，只能在 .env 里
if grep -q '^LITELLM_MASTER_KEY=sk-lc-' "$ENVF"; then
  pass "init 生成了网关 master key 并写进 .env"
else
  fail "init 没有生成 LITELLM_MASTER_KEY"
fi
# 按值查，不是按变量名查：泄漏的形态是那串 sk-lc-… 出现在 registry 里，
# 变量名本身出现在 registry 里反而无害。查错了对象的断言抓不到真正的泄漏。
MK="$(sed -n 's/^LITELLM_MASTER_KEY=//p' "$ENVF" | head -1)"
if [ -z "$MK" ]; then
  fail "读不出 .env 里的 LITELLM_MASTER_KEY，下一条断言无从谈起"
else
  refute "master key 的值没有跑进 registry.json" "$REG" "$MK"
fi

# ─────────────────────────────────────────────────────────────────────────
echo "[4] lc migrate：registry 里遗留的明文 header 值搬进 .env"
# 早期版本把 header 值明文存在 registry 里。migrate 是不可逆操作且直接动凭证
# 文件，写错会破坏已有用户的配置，所以它的每一步都要钉住。
python3 - "$REG" "$CANARY_HDR" <<'PY'
import json, sys
p = sys.argv[1]
reg = json.load(open(p, encoding="utf-8"))
reg["upstreams"]["intranet"]["headers"] = {"X-Legacy-Token": sys.argv[2] + "-legacy"}
json.dump(reg, open(p, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY

# 先确认 sync 会就着这个状态报警——不报警的话用户根本不知道要跑 migrate
run /dev/null "$WORK/log5" sync
cat "$WORK/log5"
assert "sync 对 registry 里的明文 header 值给出警告" "$WORK/log5" "明文 header 值"
assert "警告里指明了怎么修"                          "$WORK/log5" "lc migrate"

run /dev/null "$WORK/log6" migrate
cat "$WORK/log6"
assert "migrate 报告了搬运的目标变量" "$WORK/log6" "KEY_INTRANET_HEADER_X_LEGACY_TOKEN"
assert "migrate 提醒轮换可能已泄漏的凭证" "$WORK/log6" "轮换"
assert "registry 里 header 换成了变量名" "$REG" '"X-Legacy-Token": "KEY_INTRANET_HEADER_X_LEGACY_TOKEN"'
refute "registry 里明文 header 值已清除" "$REG" "$CANARY_HDR-legacy"
assert ".env 里收下了原来的明文值"       "$ENVF" "KEY_INTRANET_HEADER_X_LEGACY_TOKEN=$CANARY_HDR-legacy"
refute "migrate 之后 config.yaml 不再内联明文值" "$CFG" "$CANARY_HDR-legacy"
assert "migrate 之后 config.yaml 走 os.environ/" "$CFG" "X-Legacy-Token: os.environ/KEY_INTRANET_HEADER_X_LEGACY_TOKEN"

# 幂等：再跑一次不该重复搬运，也不该把变量名当成新的明文值再搬一层
run /dev/null "$WORK/log7" migrate
assert "migrate 是幂等的（第二次无事可做）" "$WORK/log7" "没有需要迁移"

# ─────────────────────────────────────────────────────────────────────────
echo "[5] lc add 同名覆盖：旧的 header 变量不许留在 .env 里当孤儿（issue #15）"
# header 变量名由「上游名 + 头名」派生。头名一改或那个头被去掉，旧变量就没有
# 任何配置引用它了；不清掉的话，一个不再被引用的凭证值会一直留在 .env 里，
# 并被 docker-compose 的 env_file 注入网关容器。rm 一直是清的，漏的是 add。
add_gamma() {  # add_gamma <API Key> <要不要自定义头 y/n> [头名] [头值]
  local key="$1" want="$2" hk="${3:-}" hv="${4:-}"
  {
    echo "gamma"
    # registry 里已经有 gamma 时，_add_one 会先问一句「覆盖?」；没有时这一行
    # 会被当成 Base URL 之前的多余输入，所以只在覆盖场景喂。
    [ -n "${GAMMA_EXISTS:-}" ] && echo "y"
    echo "http://gamma-$HOSTNAME_CANARY:8000/v1"
    echo "Qwen/Qwen3-4B"
    echo "$key"
    echo ""        # 上下文窗口取默认
    echo ""        # 最大输出取默认
    echo "1"       # 后端类型: vLLM
    echo "$want"
    if [ "$want" = y ]; then echo "$hk"; echo "$hv"; echo ""; fi
  } > "$WORK/ag"
  run "$WORK/ag" "$WORK/log-gamma" add
  GAMMA_EXISTS=1
}

CANARY_HDR_OLD="lc-hdr-old-canary-$$-${RANDOM}${RANDOM}"
CANARY_HDR_NEW="lc-hdr-new-canary-$$-${RANDOM}${RANDOM}"
CANARY_HDR_NEW2="lc-hdr-new2-canary-$$-${RANDOM}${RANDOM}"
CANARY_HDR_OTHER="lc-hdr-other-canary-$$-${RANDOM}${RANDOM}"
CANARY_KEY3="lc-key3-canary-$$-${RANDOM}${RANDOM}"

# 邻居上游：它的 header 变量前缀不同，任何清理都不该碰到它
cat > "$WORK/a5" <<EOF
delta
http://delta-$HOSTNAME_CANARY:8000/v1
Qwen/Qwen3-8B
$CANARY_KEY3
EOF
cat >> "$WORK/a5" <<EOF


1
y
User-Agent
$CANARY_HDR_OTHER

EOF
run "$WORK/a5" "$WORK/log8" add

add_gamma "$CANARY_KEY3" y "X-Old-Token" "$CANARY_HDR_OLD"
assert "覆盖前 .env 里有旧 header 变量" "$ENVF" "KEY_GAMMA_HEADER_X_OLD_TOKEN=$CANARY_HDR_OLD"

# (a) 换头名覆盖：旧变量必须消失，新变量必须写进去
add_gamma "$CANARY_KEY3" y "X-New-Token" "$CANARY_HDR_NEW"
cat "$WORK/log-gamma"
refute "换头名覆盖后旧 header 变量已清除"     "$ENVF" "KEY_GAMMA_HEADER_X_OLD_TOKEN"
refute "换头名覆盖后旧 header 的值不再留在 .env" "$ENVF" "$CANARY_HDR_OLD"
assert "新 header 变量正常写入"               "$ENVF" "KEY_GAMMA_HEADER_X_NEW_TOKEN=$CANARY_HDR_NEW"
assert "清理动作有一行说明（不静默）"          "$WORK/log-gamma" "KEY_GAMMA_HEADER_X_OLD_TOKEN"
refute "registry.json 里也不再引用旧头名"     "$REG" "X-Old-Token"
assert "邻居上游的 header 变量没被误删"        "$ENVF" "KEY_DELTA_HEADER_USER_AGENT=$CANARY_HDR_OTHER"

# (b) 头名不变、只换值：新值必须留下。清理顺序写反就会把用户刚输入的值删掉，
#     这条断言专门钉住那个顺序。
add_gamma "$CANARY_KEY3" y "X-New-Token" "$CANARY_HDR_NEW2"
assert "头名不变时新输入的值没被误删"          "$ENVF" "KEY_GAMMA_HEADER_X_NEW_TOKEN=$CANARY_HDR_NEW2"
refute "头名不变时旧值已被新值取代"            "$ENVF" "$CANARY_HDR_NEW"

# (c) 覆盖时干脆不要自定义头：registry 里引用没了，.env 里也不许留
add_gamma "$CANARY_KEY3" n
refute "去掉自定义头后 .env 里没有孤儿变量"    "$ENVF" "KEY_GAMMA_HEADER_"
refute "去掉自定义头后 header 的值不再留在 .env" "$ENVF" "$CANARY_HDR_NEW2"
assert "邻居上游依然完好"                     "$ENVF" "KEY_DELTA_HEADER_USER_AGENT=$CANARY_HDR_OTHER"

# ─────────────────────────────────────────────────────────────────────────
if [ "$fails" -gt 0 ]; then
  echo "=== 失败 $fails 项 ==="
  exit 1
fi
echo "=== 全部通过 ==="
