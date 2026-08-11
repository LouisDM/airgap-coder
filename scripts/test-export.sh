#!/usr/bin/env bash
# 钉住 `lc export` 打出来的离线包（issue #5）。
#
# 这个包是整个项目唯一一次真正的隔离网穿越：它离开有外网的机器、跨网传递，
# 到了内网就没有补救手段。所以最重要的断言不是「该有的都有」，而是
# 「不该带走的一个都没带」——.env / 生成的配置 / 会话库 / .git。
#
# registry.json 是例外：issue #16 之后它默认跟着包走（只存结构定义与变量名），
# 所以这里改成钉住「默认在包里 + --no-registry 时不在 + 里面还有明文凭证时
# 拒绝打包」这三条。
#
# 用法: bash scripts/test-export.sh     （零依赖，只用 Python 标准库 + tar）
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 整份测试在仓库的一份副本里跑：lc 的 ROOT 由自身路径推导，产物和造出来的
# 假 .env / registry.json 都落在 ROOT 下，不能污染开发机上的真实文件。
# 连 .git 一起复制，这样 `git ls-files` 看到的就是当前工作树的真实状态。
WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

cp -r "$REPO" "$WORK/repo"
SRC="$WORK/repo"
OUT="$WORK/out"
mkdir -p "$OUT"

# 造出该被拦住的文件。它们都被 .gitignore 排除，所以 git ls-files 看不见；
# 但这个测试的意义就在于不只依赖 gitignore 正确。
#
# 哨兵值必须在运行时现生成，不能写死一个字面量：这个脚本自己就是被打包的源码
# 之一，写死的字面量会跟着进包，于是下面那条「包的字节流里搜不到密钥」的断言
# 会被脚本自身的内容触发，自己把自己判红。
CANARY="lc-export-canary-$$-${RANDOM}${RANDOM}"

cat > "$SRC/.env" <<EOF
LITELLM_MASTER_KEY=sk-$CANARY
KEY_INTRANET=$CANARY-too
KEY_INTRANET_BASE=http://vllm.example.local:8000/v1
EOF
cp "$SRC/registry.example.json" "$SRC/registry.json"
mkdir -p "$SRC/litellm" "$SRC/codex"
echo "model_list: []" > "$SRC/litellm/config.yaml"
echo "fake sqlite with prompts" > "$SRC/codex/sessions.sqlite"

# 在 litellm 前面插一个诱饵服务：网关镜像必须按服务名定位，不能取第一条
# `image:`。取错了会把不相干的镜像打进包，而这种错要到内网才发现。
python3 - "$SRC/docker-compose.yml" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8").write(
    s.replace("services:\n",
              "services:\n  decoy-proxy:\n    image: decoy/never-package-me:1.0\n", 1))
PY

fails=0
check() {        # check assert|refute <字符串> <说明>；在 $LIST 里找
  local mode="$1" needle="$2" why="$3" hit=0
  grep -qF -e "$needle" "$LIST" && hit=1
  if { [ "$mode" = assert ] && [ "$hit" = 1 ]; } ||
     { [ "$mode" = refute ] && [ "$hit" = 0 ]; }; then
    echo "  ✅ $why"
  else
    echo "  ❌ $why"
    echo "::error::$why"
    fails=$((fails + 1))
  fi
}

echo "[1] lc export --no-images：包的内容清单"
NO_COLOR=1 python3 "$SRC/bin/lc" export --no-images --out "$OUT/bundle.tar.gz" \
  > "$OUT/log" 2>&1 || { cat "$OUT/log"; echo "::error::lc export 失败"; exit 1; }
cat "$OUT/log"
LIST="$OUT/log"
check assert "ghcr.io/berriai/litellm" "网关镜像取自 docker-compose.yml 里的 litellm 服务"
check refute "decoy/never-package-me"  "排在前面的诱饵服务没被误当成网关镜像"
LIST="$OUT/list"
tar tzf "$OUT/bundle.tar.gz" > "$LIST"

check assert "/install.sh"            "包里有 install.sh"
check assert "/MANIFEST.txt"          "包里有 MANIFEST.txt"
check assert "/bin/lc"                "包里有 bin/lc"
check assert "/README.md"             "包里有 README.md"
check assert "/registry.example.json" "包里有 registry.example.json（内网侧的最小示例）"
check assert "/docker/Dockerfile"      "包里有 Dockerfile"
check assert "/scripts/probe.py"       "包里有 scripts/"

echo "[2] 不该带走的一个都不许在包里"
# 按包内相对路径精确比对。子串匹配在这里会骗人：".env" 能在 ".env.example"
# 里找到，那是该带走的文件。
RELLIST="$OUT/rellist"
sed 's|^[^/]*/||' "$LIST" > "$RELLIST"
LIST="$RELLIST"
checkre() {      # checkre assert|refute <正则> <说明>；同样在 $LIST 里找
  local mode="$1" re="$2" why="$3" hit=0
  grep -qE "$re" "$LIST" && hit=1
  if { [ "$mode" = assert ] && [ "$hit" = 1 ]; } ||
     { [ "$mode" = refute ] && [ "$hit" = 0 ]; }; then
    echo "  ✅ $why"
  else
    echo "  ❌ $why"
    echo "::error::$why"
    fails=$((fails + 1))
  fi
}
checkre refute '^\.env$'                ".env 不在包里"
checkre assert '^registry\.json$'       "registry.json 默认在包里（结构定义，内网侧要沿用）"
checkre refute '^litellm/config\.yaml$' "生成的网关配置不在包里"
checkre refute '^codex/'                "CODEX_HOME 不在包里（会话库可能含代码与 prompt）"
checkre refute '^\.git/'                ".git 不在包里"
checkre assert '^\.env\.example$'       ".env.example 该带走，没被上面的排除规则误伤"
# 上面是按路径查，这里再按内容查一遍：密钥值绝不能出现在任何一个文件里
if gunzip -c "$OUT/bundle.tar.gz" | grep -qa "$CANARY"; then
  echo "  ❌ 包的字节流里出现了 .env 里的密钥值"
  echo "::error::包的字节流里出现了 .env 里的密钥值"
  fails=$((fails + 1))
else
  echo "  ✅ 包的字节流里搜不到 .env 里的密钥值"
fi

echo "[3] MANIFEST 的内容"
mkdir -p "$OUT/x" && tar xzf "$OUT/bundle.tar.gz" -C "$OUT/x"
DIR="$(find "$OUT/x" -maxdepth 1 -mindepth 1 -type d | head -1)"
LIST="$DIR/MANIFEST.txt"
cat "$LIST"
PIN="$(sed -n 's/^ARG CODEX_VERSION=//p' "$SRC/docker/Dockerfile" | head -1)"
check assert "$PIN"                  "MANIFEST 里的 Codex 版本取自 Dockerfile（不写死）"
check assert "ghcr.io/berriai/litellm" "MANIFEST 里记了网关镜像名"
check assert "digest"                 "MANIFEST 明确以内网侧 digest 为准"
check assert "导出时间"                "MANIFEST 记了导出时间"
# issue #16：registry.json 和 .env 的性质完全不同，并排写在「已排除」里会让
# 内网侧的人以为它也含凭证。措辞必须说清「结构定义、不含凭证」。
check assert "registry.json 已包含"    "MANIFEST 说明了 registry.json 在包里"
check assert "不含任何凭证"            "MANIFEST 说清 registry 是结构定义而不是凭证"
check refute "已排除 .env / registry.json" "MANIFEST 不再把 registry 和 .env 并列写成「已排除」"
LIST="$DIR/install.sh"
check assert "registry.json 已在包里"  "install.sh 的指引说明只需填地址与密钥"
test -x "$DIR/install.sh" \
  && echo "  ✅ install.sh 是可执行的" \
  || { echo "  ❌ install.sh 没有可执行位"; fails=$((fails + 1)); }
test -x "$DIR/bin/lc" \
  && echo "  ✅ bin/lc 的可执行位在打包后仍保留" \
  || { echo "  ❌ bin/lc 打包后丢了可执行位，内网侧要手动 chmod"; fails=$((fails + 1)); }
bash -n "$DIR/install.sh" \
  && echo "  ✅ 生成的 install.sh 语法正确" \
  || { echo "  ❌ 生成的 install.sh 语法错误"; fails=$((fails + 1)); }

echo "[4] 参数校验"
if NO_COLOR=1 python3 "$SRC/bin/lc" export --bogus > "$OUT/log2" 2>&1; then
  echo "  ❌ 未知参数应当报错退出"; fails=$((fails + 1))
else
  LIST="$OUT/log2"; check assert "未知参数" "未知参数给出明确报错而不是静默忽略"
fi

# ─────────────────────────────────────────────────────────────────────────
# 带镜像那条路需要 docker。用一个极小的镜像替身：把副本里的 Dockerfile /
# docker-compose.yml 改成指向它，就不用给生产代码开测试钩子，也不会碰到
# 开发机上真实的 litellm 镜像 tag。
#
# 开发镜像的替身必须是 build 出来的，不能是 `docker tag hello-world ...`：
# tag 只是加个别名，镜像仍带着 hello-world 的 RepoDigests，于是 MANIFEST 里
# 「本地构建、没有 RepoDigest」那条兜底分支根本不会被走到。build 一层（哪怕
# 只加个 LABEL）才会产生没有 RepoDigests 的镜像——这也正是真实开发镜像的样子。
# 网关替身则用拉下来的 hello-world，它有 RepoDigest，走真实 digest 那条分支。
# ─────────────────────────────────────────────────────────────────────────
if command -v docker >/dev/null 2>&1 &&
   docker pull -q hello-world >/dev/null 2>&1 &&
   printf 'FROM hello-world\nLABEL lc.test=1\n' |
     docker build -q -t airgap-coder:test-tiny - >/dev/null 2>&1; then
  echo "[5] 带镜像导出（用 hello-world 当镜像替身）"
  sed -i.bak 's/^ARG CODEX_VERSION=.*/ARG CODEX_VERSION=test-tiny/' "$SRC/docker/Dockerfile"
  # 替身按「仓库前缀」整行替换，不匹配 tag 或 digest 的形态（issue #13）。
  # 写死成 `litellm:` 的话，compose 换成纯 digest 形式（repo@sha256:…）后这条
  # sed 就不再匹配，替身没换上，export 会去找那个真实 digest 的镜像、本机没有、
  # 按设计拒绝打包——而报错说的是「本机没有镜像」，读的人不会想到根因是测试
  # 脚本里一条 sed 没匹配上。
  #
  # 替身本身也用 tag@digest 形式，和生产 compose 保持一致：export 要把这个
  # 引用交给 docker image inspect / docker save，形态不同真的会有差别。
  HW_DIGEST="$(docker image inspect hello-world:latest \
    --format '{{index .RepoDigests 0}}' | sed 's/.*@//')"
  test -n "$HW_DIGEST" || { echo "::error::读不出 hello-world 的 RepoDigest"; exit 1; }
  sed -i.bak "s#^[[:space:]]*image: ghcr.io/berriai/litellm.*#    image: hello-world:latest@$HW_DIGEST#" \
    "$SRC/docker-compose.yml"
  grep -q "image: hello-world:latest@sha256:" "$SRC/docker-compose.yml" \
    || { echo "::error::替身没换上，后面的断言测的不是想测的东西"; exit 1; }
  NO_COLOR=1 python3 "$SRC/bin/lc" export --out "$OUT/full.tar.gz" \
    > "$OUT/log3" 2>&1 || { cat "$OUT/log3"; echo "::error::带镜像导出失败"; exit 1; }
  cat "$OUT/log3"
  LIST="$OUT/list3"
  tar tzf "$OUT/full.tar.gz" > "$LIST"
  check assert "images/airgap-coder.tar.gz" "开发镜像 tar 在包里"
  check assert "images/litellm.tar.gz"      "网关镜像 tar 在包里"
  # digest 固定的引用要一路走通 docker image inspect 与 docker save。这两步
  # 只在带镜像那条路上发生，而它是唯一一次跨隔离网搬运——取错或取不到都要到
  # 内网才发现。
  LIST="$OUT/log3"
  check assert "hello-world:latest@sha256:" "digest 固定的网关引用被原样取到并用于打包"
  LIST="$OUT/list3"
  check assert "/SHA256SUMS"                "有 SHA256SUMS 供内网侧核完整性"

  mkdir -p "$OUT/y" && tar xzf "$OUT/full.tar.gz" -C "$OUT/y"
  DIR2="$(find "$OUT/y" -maxdepth 1 -mindepth 1 -type d | head -1)"
  ( cd "$DIR2" && sha256sum -c SHA256SUMS ) >/dev/null \
    && echo "  ✅ SHA256SUMS 与包内镜像 tar 对得上" \
    || { echo "  ❌ SHA256SUMS 校验不过"; fails=$((fails + 1)); }
  LIST="$DIR2/MANIFEST.txt"
  check assert "sha256 :" "MANIFEST 记了每个镜像 tar 的 sha256"
  check refute "decoy/never-package-me" "打进包的是 litellm 服务的镜像，不是诱饵"
  # 两条 digest 分支都要有话说，且都不许留空。这里必须用正则：check 走的是
  # grep -F，末尾的 $ 会被当成字面量，那条断言会永远为真。
  check assert "digest : sha256:" "拉取来的网关镜像记了真实 digest"
  # 本地构建的镜像有没有 RepoDigest 取决于镜像存储驱动：经典 docker（GitHub
  # runner）没有，containerd snapshotter（Docker Desktop 新默认）有。断言
  # 「必须写着无 RepoDigest」会在开发机上误报——那是环境差异，不是缺陷。
  # 真正要保证的是每条 digest 都有话说：要么真 digest，要么明确标注没有。
  if grep -E 'digest :' "$LIST" | grep -qvE 'digest :[[:space:]]*(sha256:|\(本地构建)'; then
    echo "  ❌ 有 digest 行既不是真 digest 也没明确标注"
    echo "::error::有 digest 行既不是真 digest 也没明确标注"
    fails=$((fails + 1))
  else
    echo "  ✅ 每条 digest 要么是真 digest，要么明确标注本地构建"
  fi
  checkre refute 'digest :[[:space:]]*$' "没有空的 digest 行"
  gunzip -c "$DIR2/images/litellm.tar.gz" | tar t >/dev/null \
    && echo "  ✅ 镜像 tar 是完整的 gzip+tar（流式落盘没写坏）" \
    || { echo "  ❌ 镜像 tar 坏了"; fails=$((fails + 1)); }

  echo "[6] 内网侧：真跑一遍 install.sh"
  # 这一步是整条链路的终点：包解开、校验、docker load 真的能过。
  # 只在这里能发现「包打得对但装不上」这类问题。
  if "$DIR2/install.sh" > "$OUT/install.log" 2>&1; then
    LIST="$OUT/install.log"
    check assert "镜像已就位"      "install.sh 跑通并给出下一步指引"
    check assert "docker load"     "install.sh 真的 docker load 了镜像"
    check refute "跳过 sha256 校验" "install.sh 做了 sha256 校验（没走跳过分支）"
    check assert "./bin/lc init"   "指引里第一步是 lc init"
  else
    cat "$OUT/install.log"
    echo "  ❌ install.sh 执行失败"
    echo "::error::install.sh 执行失败"
    fails=$((fails + 1))
  fi
  docker rmi airgap-coder:test-tiny >/dev/null 2>&1 || true
else
  echo "[5] 跳过带镜像导出：没有 docker 或拉不到 hello-world（不算失败）"
fi

echo "[7] registry.json 的三条路径（issue #16）"
# 默认带走已经在 [1][3] 里钉住了。这里钉住另外三条：显式不带、打包机上没有、
# 以及「registry 里还有明文凭证时必须拒绝打包」——最后这条最关键：带 registry
# 进包之后，registry 的内容就会跨网走，而早期版本把自定义头的值明文存在里面。

echo "  -- 7.1 --no-registry：显式不带"
NO_COLOR=1 python3 "$SRC/bin/lc" export --no-images --no-registry \
  --out "$OUT/noreg1.tar.gz" > "$OUT/log7" 2>&1 \
  || { cat "$OUT/log7"; echo "::error::--no-registry 导出失败"; exit 1; }
tar tzf "$OUT/noreg1.tar.gz" | sed 's|^[^/]*/||' > "$OUT/list7"
LIST="$OUT/list7"
checkre refute '^registry\.json$' "--no-registry 时 registry.json 不在包里"
checkre assert '^bin/lc$'         "--no-registry 只影响 registry，源码照常带走"
mkdir -p "$OUT/z7" && tar xzf "$OUT/noreg1.tar.gz" -C "$OUT/z7"
DIR7="$(find "$OUT/z7" -maxdepth 1 -mindepth 1 -type d | head -1)"
LIST="$DIR7/MANIFEST.txt"
check assert "--no-registry 导出" "MANIFEST 说清了为什么不含 registry"
LIST="$DIR7/install.sh"
check assert "本包不含 registry.json" "install.sh 提醒内网侧要完整配置"

echo "  -- 7.2 打包机上没有 registry.json：正常打包，但要说清楚"
mv "$SRC/registry.json" "$OUT/registry.saved.json"
NO_COLOR=1 python3 "$SRC/bin/lc" export --no-images --out "$OUT/noreg2.tar.gz" \
  > "$OUT/log8" 2>&1 \
  || { cat "$OUT/log8"; echo "::error::打包机没有 registry.json 时导出应当正常完成"; exit 1; }
mkdir -p "$OUT/z8" && tar xzf "$OUT/noreg2.tar.gz" -C "$OUT/z8"
DIR8="$(find "$OUT/z8" -maxdepth 1 -mindepth 1 -type d | head -1)"
LIST="$DIR8/MANIFEST.txt"
check assert "打包机上没有这个文件" "MANIFEST 说明本包不含 registry 及其原因"
check assert "lc init"             "MANIFEST 指出内网侧要完整配置"
mv "$OUT/registry.saved.json" "$SRC/registry.json"

echo "  -- 7.3 registry 里还有明文 header 值：必须拒绝打包"
# 这是带 registry 进包之后新增的泄漏面：明文值会跟着包跨网走，而包宣称不含机密。
LEAK_CANARY="lc-legacy-canary-$$-${RANDOM}${RANDOM}"
cp "$SRC/registry.json" "$OUT/registry.clean.json"
python3 - "$SRC/registry.json" "$LEAK_CANARY" <<'PY'
import json, sys
p = sys.argv[1]
reg = json.load(open(p, encoding="utf-8"))
name = sorted(reg["upstreams"])[0]
reg["upstreams"][name]["headers"] = {"X-Legacy-Token": sys.argv[2]}
json.dump(reg, open(p, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY
if NO_COLOR=1 python3 "$SRC/bin/lc" export --no-images --out "$OUT/leak.tar.gz" \
     > "$OUT/log9" 2>&1; then
  echo "  ❌ registry 里有明文凭证时仍然打出了包"
  echo "::error::registry 里有明文凭证时仍然打出了包"
  fails=$((fails + 1))
  gunzip -c "$OUT/leak.tar.gz" | grep -qa "$LEAK_CANARY" \
    && { echo "  ❌ 而且那个明文凭证真的进了包"; fails=$((fails + 1)); }
else
  LIST="$OUT/log9"
  check assert "明文 header 值" "拒绝的理由说清楚了是明文 header 值"
  check assert "lc migrate"     "报错里给出了修法（migrate）"
  check assert "--no-registry"  "报错里给出了另一条出路（--no-registry）"
  test -e "$OUT/leak.tar.gz" \
    && { echo "  ❌ 拒绝之后不该留下半个包"; fails=$((fails + 1)); } \
    || echo "  ✅ 拒绝之后没有留下产物"
fi
cp "$OUT/registry.clean.json" "$SRC/registry.json"

echo "[8] compose 里的网关镜像：三种写法都要解析对（issue #13）"
# docker-compose.yml 已经用 digest 固定网关镜像。_compose_litellm_image() 是
# 按服务名逐行扫的手写解析器，取错了会把不相干的镜像打进包，而这种错要到内网
# 才发现。三种合法写法都钉住，以后换成纯 digest 也不会静默走样。
#
# 不需要 docker：--no-images 只要求解析出镜像名，不要求本机真有那个镜像。
# 基准取自仓库里那份 compose，不是 $SRC 那份——[5] 已经把 $SRC 的镜像换成替身了
cp "$REPO/docker-compose.yml" "$OUT/compose.repo.yml"
parse_image() {   # parse_image <compose 里 litellm 的 image: 值> <说明>
  python3 - "$SRC/docker-compose.yml" "$1" <<'PY'
import sys
# 保留诱饵服务：它排在 litellm 前面，解析器不能取「第一条 image:」
open(sys.argv[1], "w", encoding="utf-8").write(
    "services:\n"
    "  decoy-proxy:\n    image: decoy/never-package-me:1.0\n"
    "  litellm:\n    image: %s\n    container_name: gw\n" % sys.argv[2])
PY
  NO_COLOR=1 python3 "$SRC/bin/lc" export --no-images --no-registry \
    --out "$OUT/parse.tar.gz" > "$OUT/log-parse" 2>&1 \
    || { cat "$OUT/log-parse"; echo "::error::解析 $1 时导出失败"; exit 1; }
  LIST="$OUT/log-parse"
  check assert "网关镜像 : $1" "$2"
  check refute "decoy/never-package-me" "$2：没被前面的诱饵服务带偏"
}
PINNED="$(sed -n 's#^[[:space:]]*image:[[:space:]]*\(ghcr.io/berriai/litellm[^[:space:]]*\).*#\1#p' \
  "$OUT/compose.repo.yml" | head -1)"
test -n "$PINNED" || { echo "::error::读不出仓库里 compose 的网关镜像引用"; exit 1; }
parse_image "$PINNED"                       "仓库当前的写法（$PINNED）"
parse_image "ghcr.io/berriai/litellm@sha256:0000000000000000000000000000000000000000000000000000000000000000" \
                                            "纯 digest 写法"
parse_image "ghcr.io/berriai/litellm:main-stable" "纯 tag 写法（旧格式仍能读）"
cp "$OUT/compose.repo.yml" "$SRC/docker-compose.yml"

# 仓库里那份 compose 必须是 digest 固定的。scripts/test-project-metadata.py 已经
# 有一条同样的断言；这里再钉一次是因为 export 是唯一一次跨隔离网搬运，
# 「两台机器 docker compose pull 拿到不同网关」的后果发生在没有外网的那一侧。
if grep -qE '^[[:space:]]*image:[[:space:]]*ghcr.io/berriai/litellm[^[:space:]]*@sha256:[0-9a-f]{64}' \
     "$OUT/compose.repo.yml"; then
  echo "  ✅ docker-compose.yml 的网关镜像由 digest 固定，不是移动 tag"
else
  echo "  ❌ docker-compose.yml 的网关镜像没有 digest，两台机器可能拿到不同的网关"
  echo "::error::docker-compose.yml 的网关镜像没有 digest"
  fails=$((fails + 1))
fi

if [ "$fails" -gt 0 ]; then
  echo "=== 失败 $fails 项 ==="
  exit 1
fi
echo "=== 全部通过 ==="
