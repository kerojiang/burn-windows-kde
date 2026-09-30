#!/usr/bin/env bash
# KCM QML 界面测试 —— bash tests/test_kcm_qml.sh
#
# 自动化方案：QML 内的 console.log 探针 → journal（spec 实测：KCM 的 QML console
# 输出进 journal，且 Qt 会带上 qrc:/ 源路径前缀）。测试通过 `journalctl --since @epoch`
# 圈定本轮启动产生记录，避免历史输出干扰。
#
# 需要：本机 KWin/Plasma 运行（kcmshell6 起 GUI）、SUDO_PASSWORD 或 sudo 缓存
# （KCM 必须装进系统路径才能按名加载，见 test_kcm_build.sh）。
set -u

# i18n（2026-09-30）：文案原文已统一英文（KDE 规范），测试固定 C locale →
# i18n() fallback 返回英文原文，断言不依赖 .mo 是否安装（与探针字面量
# 「不依赖翻译环境」的既有 Ruling 同源）。
export LANG=C LC_ALL=C

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KCM_SRC="$ROOT/kcm"
KCM_DEST="/usr/lib/qt6/plugins/plasma/kcms/systemsettings/kcm_burnwindow.so"
REAL_EFFECTS="$HOME/.local/share/kwin/effects"

PASS=0
FAIL=0
SKIP=0
OUTPUT=""
RC=0
BUILD=""
PREFIX=""
CFG=""
# ---- 保护测试开始前已存在的系统 KCM（M-2，与 test_kcm_build.sh 同一套约定）----
KCM_BACKUP_DIR=""     # 进入测试时 KCM_DEST 的内容快照
KCM_WAS_PRESENT=0     # 进入测试时目标是否已存在
KCM_SNAPSHOT_DONE=0   # 快照是否已执行 —— 未快照时 restore 必须不动目标
KCM_RESTORED=0        # 恢复动作只执行一次（显式路径与 trap 兜底共用）
KCM_PRESET_CLEANED=0  # 占位清理只执行一次
PRESET_FILE=""        # 用例 0 预置的占位 KCM（断言"原样保留"的比对源）
KCM_INITIAL_PRESENT=0 # 预置动作之前的初始状态（断言"净影响为零"用）

setup() {
  BUILD="$(mktemp -d /tmp/bmw-qml-build.XXXXXX)"
  PREFIX="$(mktemp -d /tmp/bmw-qml-prefix.XXXXXX)"
  CFG="$PREFIX/burn-window-randomrc"

  # 预置特效 fixture：install.sh 从 PREFIX/effects 现场提取 19 个池成员，
  # 与真实安装路径解耦（不触碰 ~/.local/share/kwin/effects）
  mkdir -p "$PREFIX/effects"
  local d id src
  for d in "$REAL_EFFECTS"/*/; do
    [ -e "$d" ] || continue
    id="$(basename "$d")"
    mkdir -p "$PREFIX/effects/$id/contents/code" "$PREFIX/effects/$id/contents/config"
    cp "$d/metadata.json" "$PREFIX/effects/$id/" 2>/dev/null || true
    # fixture 必须是上游纯净态（真实环境 e2e 首装后已注入，inject.py 会 exit 2）
    src="$d/contents/code/main.js.orig"
    [ -e "$src" ] || src="$d/contents/code/main.js"
    cp "$src" "$PREFIX/effects/$id/contents/code/main.js" 2>/dev/null || true
    # 参数模型（Task 7）：main.xml 是 params 自渲染的数据源，缺失则参数面板为空
    cp "$d/contents/config/main.xml" "$PREFIX/effects/$id/contents/config/" 2>/dev/null || true
  done
}

teardown() {
  [ -n "${BUILD:-}" ] && rm -rf "$BUILD"
  [ -n "${PREFIX:-}" ] && rm -rf "$PREFIX"
}

run() {
  set +e
  OUTPUT="$("$@" 2>&1)"
  RC=$?
  set +e
}

fail() {
  FAIL=$((FAIL + 1))
  printf '  ✖ %s\n    %s\n    %s\n' "$1" "$2" "${OUTPUT:0:300}"
}
pass() { PASS=$((PASS + 1)); printf '  ✔ %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf '  ⊘ %s —— %s\n' "$1" "$2"; }

assert_eq() {
  if [ "$1" = "$2" ]; then pass "$3"; else fail "$3" "期望 [$2] 实际 [$1]"; fi
}
assert_contains() {
  case "$OUTPUT" in
    *"$1"*) pass "$2" ;;
    *) fail "$2" "应包含 [$1]" ;;
  esac
}
assert_not_contains() {
  case "$OUTPUT" in
    *"$1"*) fail "$2" "不应包含 [$1]" ;;
    *) pass "$2" ;;
  esac
}

# 提权通道（与 test_kcm_build.sh 同一套约定）：缓存优先，其次 SUDO_PASSWORD，
# 皆无则由调用方标记 SKIP。凭据只经环境变量传入，不写入本文件。
sudo_available() { sudo -n true 2>/dev/null || [ -n "${SUDO_PASSWORD:-}" ]; }
sudo_cmd() {
  if sudo -n true 2>/dev/null; then
    sudo "$@"
  elif [ -n "${SUDO_PASSWORD:-}" ]; then
    printf '%s\n' "$SUDO_PASSWORD" | sudo -S "$@"
  else
    echo "sudo 凭据不可用" >&2
    return 1
  fi
}

# ---------------------------------------------------- 系统 KCM 快照/还原（M-2）
# 进入测试时快照 KCM_DEST，退出时原样还原 —— 只有"进入时不存在"（本次新装）
# 才删除。旧版无条件 install + 无条件 rm，会让用户经 install.sh 正式安装的
# KCM 在跑完测试后从系统设置里消失。
snapshot_kcm() {
  KCM_SNAPSHOT_DONE=1
  [ "${KCM_WAS_PRESENT:-0}" -eq 1 ] && return 0
  [ -e "$KCM_DEST" ] || return 0
  KCM_BACKUP_DIR="$(mktemp -d /tmp/bmw-qml-snap.XXXXXX)"
  if cp "$KCM_DEST" "$KCM_BACKUP_DIR/kcm_burnwindow.so" 2>/dev/null \
     && [ -s "$KCM_BACKUP_DIR/kcm_burnwindow.so" ]; then
    KCM_WAS_PRESENT=1
  else
    echo "  快照失败，退出时不删除 $KCM_DEST" >&2
    rm -rf "$KCM_BACKUP_DIR"
    KCM_BACKUP_DIR=""
    KCM_WAS_PRESENT=1   # 文件在但拿不到内容：视为"已存在"，退出时保留
  fi
}

restore_kcm() {
  [ "${KCM_RESTORED:-0}" -eq 1 ] && return 0
  # 从未快照 = 脚本极早期失败：无法区分用户安装与本次新装，一律不动
  [ "${KCM_SNAPSHOT_DONE:-0}" -eq 1 ] || return 0
  if ! sudo_available; then
    echo "  sudo 凭证不可用，保留 $KCM_DEST（快照: ${KCM_WAS_PRESENT:-0}）"
    return 0
  fi
  KCM_RESTORED=1
  if [ "${KCM_WAS_PRESENT:-0}" -eq 0 ]; then
    sudo_cmd rm -f "$KCM_DEST" && echo "  已删除 $KCM_DEST"
  elif [ -f "$KCM_BACKUP_DIR/kcm_burnwindow.so" ]; then
    if sudo_cmd install -D -m 0644 "$KCM_BACKUP_DIR/kcm_burnwindow.so" "$KCM_DEST"; then
      echo "  已还原测试开始前的 KCM: $KCM_DEST"
    else
      echo "  还原失败: $KCM_DEST（备份仍在 $KCM_BACKUP_DIR）" >&2
      KCM_RESTORED=0
    fi
  else
    echo "  快照内容缺失，保留 $KCM_DEST 不动" >&2
  fi
}

# 占位文件由本测试自己放置，最终必须清掉；初始就已存在时 PRESET_FILE 为空
cleanup_preset() {
  [ "${KCM_PRESET_CLEANED:-0}" -eq 1 ] && return 0
  [ -n "${PRESET_FILE:-}" ] || return 0
  KCM_PRESET_CLEANED=1
  sudo_available || return 0
  sudo_cmd rm -f "$KCM_DEST" >/dev/null 2>&1 || true
}

# 中途任何 exit（构建失败/提权失败/前置 install 失败）都要还原并清占位
trap 'restore_kcm; cleanup_preset' EXIT

# 启动一次 KCM 并收集本轮 journal；结果放 $OUTPUT（供 assert_contains 断言）。
# $1 = 传给 KCM 的额外环境变量（如 Blacklist 已由外部写入配置，此处只传路径）。
launch_and_collect() {
  local t0
  t0="$(date +%s)"
  # BMW_KCM_KWINRC 指向 prefix 空文件：参数值全部回落 main.xml default，
  # 断言不被用户真实 kwinrc 的现值干扰（Task 6 引入的读侧隔离）
  env BURN_WINDOW_CONFIG="$CFG" BURN_WINDOW_EFFECTS="$PREFIX/effects" \
    BMW_KCM_KWINRC="$PREFIX/kwinrc" \
    timeout -k 5 20 kcmshell6 kcm_burnwindow >/dev/null 2>&1 &
  local pid=$!
  sleep 4                      # 等 QML 加载并把探针刷进 journal
  kill "$pid" 2>/dev/null
  sleep 1
  kill -9 "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null

  set +e
  OUTPUT="$(journalctl --user -o cat --since "@$t0" 2>/dev/null)"
  RC=$?
  set +e
}

# ---------------------------------------------------------------- 前置
echo "=== 前置：构建并安装 KCM ==="
setup

# ============================================================ 0. 保护已装产物
# 放在构建之前：构建失败走 exit 1 时快照必须已存在，否则 restore 会把
# "从未快照"误判成"本次新装"并删掉用户正式安装的 KCM。
echo "=== 前置：保护测试开始前已存在的系统 KCM ==="
KCM_INITIAL_PRESENT=0
[ -e "$KCM_DEST" ] && KCM_INITIAL_PRESENT=1
if sudo_available; then
  if [ "$KCM_INITIAL_PRESENT" -eq 1 ]; then
    echo "  系统路径已有 KCM（视为用户正式安装），不预置，直接以其为保护对象"
  else
    PRESET_FILE="$BUILD/preset-kcm.so"
    printf 'BMW_KCM_PRESET_STANDBY' > "$PRESET_FILE"
    run sudo_cmd install -D -m 0644 "$PRESET_FILE" "$KCM_DEST"
    if [ "$RC" -eq 0 ]; then
      pass "已预置占位 KCM（模拟用户正式安装）"
    else
      fail "已预置占位 KCM（模拟用户正式安装）" "退出码 $RC"
      PRESET_FILE=""
    fi
  fi
else
  skip "预置占位 KCM" "sudo 凭据不可用"
fi
# 必须在预置之后快照：快照内容就是"退出时必须还原成的样子"
snapshot_kcm

run cmake -S "$KCM_SRC" -B "$BUILD" -G Ninja
if [ "$RC" -ne 0 ]; then
  fail "CMake configure" "构建失败"
  echo; echo "结果: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 1
fi
run cmake --build "$BUILD"
if [ "$RC" -ne 0 ]; then
  fail "CMake build" "构建失败"
  echo; echo "结果: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 1
fi
pass "KCM 构建成功"

SO="$BUILD/bin/plasma/kcms/systemsettings/kcm_burnwindow.so"
if [ ! -f "$SO" ]; then
  skip "全部 QML 用例" "构建产物缺失: $SO"
  teardown
  echo; echo "结果: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 1
fi

if ! sudo_available; then
  skip "全部 QML 用例" "sudo 凭据不可用（缓存对子脚本无效且未提供 SUDO_PASSWORD）"
  teardown
  echo; echo "结果: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0
fi

run sudo_cmd install -D -m 0644 "$SO" "$KCM_DEST"
if [ "$RC" -ne 0 ]; then
  fail "安装到系统路径" "提权安装失败"
  teardown
  echo; echo "结果: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 1
fi
pass "已安装到系统路径"

# 首装生成配置（Pool=19 个成员、注入、apply 脚本），再按用例改 Blacklist
run bash "$ROOT/install.sh" --prefix "$PREFIX" --skip-sudo --skip-build --skip-kwinrc
if [ "$RC" -ne 0 ]; then
  fail "install.sh 生成测试配置" "退出码 $RC"
  teardown
  echo; echo "结果: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 1
fi
pass "配置与注入就绪（Pool=$(kreadconfig6 --file "$CFG" --group General --key Pool | tr ',' '\n' | grep -c .) 项）"

# ================================================================ 1. QML 渲染探针
echo "=== test_qml_renders_probe_to_journal ==="
launch_and_collect
assert_contains "BMW_KCM_QML_LOADED" "QML 探针进入 journal"
assert_contains "BMW_KCM_QML_URL=qrc:/kcm/kcm_burnwindow/main.qml" "QRC 路径正确（探针主动输出自身 URL）"
# 审查 M-6：applyRunning 原是死属性（kcm.h:28-29 声称"QML 用它禁用 Apply 按钮"，
# 但 main.qml 中 grep applyRunning 零命中）。断言 QML 真的读取了它。
assert_contains "BMW_KCM_APPLY_RUNNING=false" "QML 读取 kcm.applyRunning（初始为 false）"

# ================================================================ 2. checked 反映参与语义（D3）
echo "=== test_checkbox_checked_reflects_participating ==="
kwriteconfig6 --file "$CFG" --group General --key Blacklist "kwin6_effect_fire"
launch_and_collect
# 反转后的语义：checked = participating = 不在黑名单
assert_contains "BMW_KCM_ITEM kwin6_effect_fire checked=false" "黑名单中的 fire → 不参与 → checked=false"
assert_contains "BMW_KCM_ITEM kwin6_effect_doom checked=true" "未入黑名单的 doom → 参与 → checked=true"
assert_contains "BMW_KCM_PARTICIPATING kwin6_effect_fire=false" "PARTICIPATING 探针：fire 反转映射为 false"
assert_contains "BMW_KCM_PARTICIPATING kwin6_effect_doom=true" "PARTICIPATING 探针：doom 反转映射为 true"

# ================================================================ 3. 19 项全部渲染
echo "=== test_all_19_items_rendered ==="
POOL_COUNT="$(kreadconfig6 --file "$CFG" --group General --key Pool | tr ',' '\n' | grep -c .)"
ITEM_COUNT="$(printf '%s' "$OUTPUT" | grep -c 'BMW_KCM_ITEM ')"
assert_eq "$ITEM_COUNT" "$POOL_COUNT" "渲染项数 == Pool 长度 ($POOL_COUNT)"
assert_eq "$ITEM_COUNT" "19" "渲染项数 == 19"

# ================================================================ 4. 默认全参与 + 开关只读徽标
echo "=== test_participating_default_all_checked ==="
kwriteconfig6 --file "$CFG" --group General --key Blacklist ""
launch_and_collect
TRUE_N="$(printf '%s' "$OUTPUT" | grep -cE 'BMW_KCM_PARTICIPATING [a-z0-9_]+=true')"
FALSE_N="$(printf '%s' "$OUTPUT" | grep -cE 'BMW_KCM_PARTICIPATING [a-z0-9_]+=false')"
assert_eq "$TRUE_N" "19" "黑名单为空 → 19 个成员全部 participating=true（勾上=参与）"
assert_eq "$FALSE_N" "0" "无 participating=false 的成员"

echo "=== test_switch_badge_rendered ==="
# i18n 后徽标走 i18n("Random effects: Enabled/Disabled")，探针值随显示文本
# 的状态词走（LANG=C 下 = 英文原文）
if printf '%s' "$OUTPUT" | grep -qE 'BMW_KCM_SWITCH_BADGE=(Enabled|Disabled)'; then
  pass "开关徽标只读探针存在（值域 Enabled|Disabled，i18n 英文原文）"
else
  fail "开关徽标只读探针存在（值域 Enabled|Disabled）" "未找到 BMW_KCM_SWITCH_BADGE 行"
fi
# D6：页面不得出现任何 toggle 开关 —— 静态断言（不依赖 journal）
if grep -qE 'setRandomLoaded|toggleLoaded|QQC2\.Switch[ {]' "$KCM_SRC/ui/main.qml"; then
  fail "页面无 toggle 开关（D6 只读徽标）" "main.qml 出现开关类调用/控件"
else
  pass "页面无 toggle 开关（D6 只读徽标）"
fi

# ================================================================ 5. 参数面板渲染与初始值
echo "=== test_param_widgets_rendered ==="
assert_contains "BMW_KCM_PARAM_WIDGET kwin6_effect_fire Duration UInt" "fire Duration 的 UInt 控件已渲染"
assert_contains "BMW_KCM_PARAM_WIDGET kwin6_effect_glitch Strength Double" "glitch Strength 的 Double 控件已渲染"

echo "=== test_param_control_wiring ==="
# 隔离 kwinrc 为空（launch_and_collect 用 prefix 空文件）→ 初始值必须回落 default
assert_contains "BMW_KCM_PARAM_EDIT kwin6_effect_fire Duration=1500" "fire Duration 初始值 = main.xml default 1500"

# ================================================================ 6. 行操作按钮（需求1：纯图标 + tooltip）
# 参数入口按钮必须是图标（icon.name）而非文字，tooltip 承载说明文案
echo "=== test_row_action_buttons ==="
assert_contains "BMW_KCM_GEAR kwin6_effect_fire icon=settings-configure" "fire 的齿轮图标（icon=settings-configure，无文字标签）"
assert_contains "tooltip=" "齿轮按钮暴露 tooltip 文案"
GEAR_N="$(printf '%s' "$OUTPUT" | grep -c 'BMW_KCM_GEAR ')"
assert_eq "$GEAR_N" "19" "齿轮渲染数 == 19（每行一个）"

# ================================================================ 7. 高度几何探针（需求4诊断）
# 现象「内容不多但页面被撑高」根因未定 —— 探针进 journal 供定位，
# 不断言具体数值（高度预期值待实测后才可断言）
echo "=== test_geometry_probe ==="
assert_contains "BMW_KCM_GEOM " "高度几何探针进 journal（page/contentH/viewport/col）"

# ================================================================ 8. 全选/全不选按钮
# 单个切换按钮：状态自适应文案（未全选→「Select All」，已全选→「Deselect
# All」）。i18n 后原文英文，LANG=C 下显示英文原文。
# 初始默认全部勾选 → 应显示「Deselect All」。
echo "=== test_select_all_button ==="
assert_contains "BMW_KCM_SELECT_ALL initial allSelected=true text=Deselect All" "按钮初始态：默认全选 → 文案 Deselect All（i18n 英文原文）"
# 点击后的行为（blacklistNow 空/满）需真实点击，journal 断言由手动验收完成；
# 这里先静态保证点击探针在源码里存在，防止被误删后手动验收无日志可读
if grep -q 'BMW_KCM_SELECT_ALL clicked' "$KCM_SRC/ui/main.qml"; then
  pass "onClicked 点击探针存在（手动验收断言 blacklistNow 用）"
else
  fail "onClicked 点击探针存在（手动验收断言 blacklistNow 用）" "main.qml 缺 clicked 探针"
fi
# 勾选绑定必须走 kcm.blacklist（带 NOTIFY blacklistChanged）——
# 若退回 modelData.participating（pool 是 CONSTANT、快照不更新，kcm.h:26 +
# kcm.cpp:115-131 实证），全选按钮的程序化批量改将无法刷新界面
if grep -q 'checked: kcm.blacklist.indexOf' "$KCM_SRC/ui/main.qml"; then
  pass "勾选绑定走 kcm.blacklist（NOTIFY 驱动，批量改可刷新）"
else
  fail "勾选绑定走 kcm.blacklist（NOTIFY 驱动，批量改可刷新）" "checked 未绑定 blacklist"
fi

# ================================================================ 9. 预览按钮（B plan Task 3）
# 每行齿轮左侧一个纯图标预览按钮；点击开临时窗口播一次该特效。
# 协议格式 BMW_PREVIEW:<effectId> 由 lib/arbiter.js 的 bmwPreviewTarget 消费。
echo "=== test_preview_button ==="
assert_contains "BMW_KCM_PREVIEW kwin6_effect_fire icon=media-playback-start" "fire 预览按钮（纯图标 media-playback-start）"
PREVIEW_N="$(printf '%s' "$OUTPUT" | grep -c 'BMW_KCM_PREVIEW ')"
assert_eq "$PREVIEW_N" "19" "预览按钮渲染数 == 19"
# 窗口标题协议必须在源码里（Task 4 的 e2e 依赖该字面量格式）
if grep -q 'BMW_PREVIEW:' "$KCM_SRC/ui/main.qml"; then
  pass "窗口标题携带 BMW_PREVIEW: 协议前缀"
else
  fail "窗口标题携带 BMW_PREVIEW: 协议前缀" "main.qml 缺协议字面量"
fi

# ================================================================ 10. 系统设置窗口高度 ~900（需求4 第二轮，方案B根因修复）
# 用户澄清「窗口非常高」指 "配置-系统设置" 主窗口本身（实测 1347）。
# 诊断结论（IMPLSEQ/WINSEQ 探针实测）：宿主 SizeViewToRootObject 按本页
# implicitHeight 调窗口，而加载瞬间 rootColumn 子项 implicit 未收敛产生
# 峰值 1365（主题/字体异步应用前的默认值），窗口被推到 1365 后不回收 →
# 钳到工作区 1347。客户端直接 resize 被 Wayland 拒（实测 winH 恒 1347）。
# 修法：burnRoot.implicitHeight 封顶 900 —— 稳态 884 不触发 min（零行为
# 变化），峰值 1365→900 → 宿主按 900 调窗；展开参数 1256→900 页内滚动。
echo "=== test_window_height ==="
# 静态：implicitHeight 封顶绑定在源码里（根因修复的实现特征）
if grep -q 'Math.min(rootColumn.implicitHeight' "$KCM_SRC/ui/main.qml"; then
  pass "源码含 implicitHeight 封顶绑定（峰值 1365→900）"
else
  fail "源码含 implicitHeight 封顶绑定" "main.qml 缺 Math.min(rootColumn.implicitHeight...) 封顶"
fi
# 运行时：窗口真实高度 ∈ [890,930] —— 判 winH（GEOM 探针字段，注意行格式
# 是 "GEOM initial winWH=... implWH=... winH=..." —— winWH/implWH 在前，
# 模式不能写 "GEOM initial winH=" 否则永不匹配）。范围覆盖两种实测关系：
# 窗口=implicit(900) 与 =implicit+chrome(914)（898=884+14 与 1365=1365
# 两种关系在时序中并存，chrome 归属未定）。超出即封顶未生效（winH=1347 =
# 峰值窗口未回落）或封顶过紧（<890 挤压稳态 884）。
if printf '%s' "$OUTPUT" | grep -qE 'winH=(89[0-9]|9[0-2][0-9])'; then
  pass "窗口真实高度 900±（内容封顶驱动）"
else
  fail "窗口真实高度 900±" "实测: $(printf '%s' "$OUTPUT" | grep -oE 'winH=[0-9.]+' | head -1)"
fi

# ================================================================ 11. i18n 中英双语（设计批准 2026-09-30）
# 原文英文（KDE 规范）+ 翻译域注册 + po 译文 + metadata 语言键。
# 头部已 export LANG=C → 运行时 i18n fallback 英文原文（第 4/8 节断言消费），
# 本节为静态断言：域/po/语言键/文案原文的源码特征，不依赖 .mo 安装。
echo "=== test_i18n ==="
# 翻译域：无域则中文环境取不到译文（i18n 恒回原文）
if grep -q 'setApplicationDomain("kcm_burnwindow")' "$KCM_SRC/kcm.cpp"; then
  pass "翻译域已注册（setApplicationDomain kcm_burnwindow）"
else
  fail "翻译域已注册" "kcm.cpp 缺 setApplicationDomain(\"kcm_burnwindow\")"
fi
# 文案原文不得再是中文（中文改由 po 译文提供）
if grep -qP 'i18n\("[^"]*[\p{Han}]' "$KCM_SRC/ui/main.qml"; then
  fail "QML i18n 原文统一英文" "main.qml 存在中文 i18n 原文：$(grep -oP 'i18n\("[^"]*[\p{Han}][^"]*"' "$KCM_SRC/ui/main.qml" | head -1)"
else
  pass "QML i18n 原文统一英文（中文由 po 提供）"
fi
# 裸中文字面量清零：徽标必须走 i18n（探针值同样经 i18n）
if grep -q 'i18n("Random effects:' "$KCM_SRC/ui/main.qml"; then
  pass "徽标文案走 i18n（Random effects: ...）"
else
  fail "徽标文案走 i18n" "main.qml 缺 i18n(\"Random effects: ...\")"
fi
# po 文件 + 关键 msgid（Select All/Deselect All 供第 4/8 节语义，Preview 对齐上游 pot）
PO="$KCM_SRC/po/zh_CN.po"
if [ -f "$PO" ] && grep -q 'msgid "Select All"' "$PO" && grep -q 'msgid "Deselect All"' "$PO" && grep -q 'msgid "Preview this effect"' "$PO"; then
  pass "kcm/po/zh_CN.po 存在且含关键 msgid"
else
  fail "kcm/po/zh_CN.po 存在且含关键 msgid" "PO=$PO 缺失或缺 Select All/Deselect All/Preview this effect"
fi
# displayName locale 感知：聚合页特效名随语言切换，且必须有 zh_Hans 档
# （KDE 中文语言代码惯例 zh_Hans；基础链 Name[locale]→Name[locale简码]→Name
#   覆盖不到 zh_CN→zh_Hans 的映射，缺档则中文环境落英文）
if grep -q 'zh_Hans' "$KCM_SRC/kcm.cpp"; then
  pass "effectDisplayName 含 zh_Hans 档（KDE 中文 locale fallback）"
else
  fail "effectDisplayName 含 zh_Hans 档" "kcm.cpp locale 链缺 zh_Hans 中间档"
fi
# 占位 metadata 双语键：zh_CN 主键（KWin 官方惯例，KPluginMetaData 按 zh_CN
# 查，系统 /usr/share/kwin/effects 实证 Name[zh_CN]、零个 zh_Hans）+ zh_Hans 兼容
if grep -q 'Name\[zh_CN\]' "$ROOT/placeholder/kwin6_effect_bmw_random/metadata.json" \
   && grep -q 'Name\[zh_Hans\]' "$ROOT/placeholder/kwin6_effect_bmw_random/metadata.json"; then
  pass "占位 metadata 含 zh_CN/zh_Hans 双语言键"
else
  fail "占位 metadata 含 zh_CN/zh_Hans 双语言键" "placeholder metadata 缺 zh_CN 或 zh_Hans 键"
fi
# 19 特效语言键：唯一落点 inject.py --patch-metadata（install.sh 解压 tar 后调用）；
# 要求 zh_CN/zh_Hans 双键（KWin 按 zh_CN 查，KCM 手写链两档都查）
if grep -q 'Name\[zh_CN\]' "$ROOT/lib/inject.py" && grep -q 'Name\[zh_Hans\]' "$ROOT/lib/inject.py"; then
  pass "inject.py --patch-metadata 含 19 特效双语言键 patch"
else
  fail "inject.py --patch-metadata 含 19 特效双语言键 patch" "inject.py 缺 zh_CN 或 zh_Hans 逻辑"
fi
# 参数名走 i18n（聚合页参数面板文案，动态 msgid 查我们 catalog）
if grep -qE 'i18n\([^\"]*modelData\.name' "$KCM_SRC/ui/main.qml"; then
  pass "参数名走 i18n（动态 msgid）"
else
  fail "参数名走 i18n（动态 msgid）" "main.qml 参数名未包 i18n"
fi

# ================================================================ 12. i18n 中文环境运行时（S10）
# mo 由前置 install.sh 的 do_install_i18n 装入 ~/.local/share/locale；系统有
# zh_CN.utf8（locale -a 实测）→ i18n 按 burn-window catalog 取中文译文。
# 第 4/8 节已断言 LANG=C 英文原文，本节补齐中文侧 —— 双语切换运行时实证。
echo "=== test_i18n_zh_runtime ==="
MO_FILE="$HOME/.local/share/locale/zh_CN/LC_MESSAGES/kcm_burnwindow.mo"
if [ ! -f "$MO_FILE" ]; then
  skip "zh_CN 运行时双语断言" "mo 未安装: $MO_FILE"
elif ! locale -a 2>/dev/null | grep -q 'zh_CN.utf8'; then
  skip "zh_CN 运行时双语断言" "系统无 zh_CN.utf8 locale"
else
  ZH_T0="$(date +%s)"
  # LANG/LC_ALL 覆盖脚本头部的 export LANG=C；其余隔离环境同 launch_and_collect
  #（prefix 配置/特效，不触真实 kwinrc）
  env LANG=zh_CN.UTF-8 LC_ALL=zh_CN.UTF-8 \
    BURN_WINDOW_CONFIG="$CFG" BURN_WINDOW_EFFECTS="$PREFIX/effects" \
    BMW_KCM_KWINRC="$PREFIX/kwinrc" \
    timeout -k 5 20 kcmshell6 kcm_burnwindow >/dev/null 2>&1 &
  ZH_PID=$!
  sleep 4
  kill "$ZH_PID" 2>/dev/null
  sleep 1
  kill -9 "$ZH_PID" 2>/dev/null
  wait "$ZH_PID" 2>/dev/null
  ZH_OUTPUT="$(journalctl --user -o cat --since "@$ZH_T0" 2>/dev/null)"
  if printf '%s' "$ZH_OUTPUT" | grep -qE 'BMW_KCM_SWITCH_BADGE=(已启用|未启用)'; then
    pass "zh_CN 环境徽标取 po 译文（已启用|未启用）"
  else
    # 诊断字段：locale 警告（env 是否传入）/ QML 是否加载 / mo 双落点状态 ——
    # 区分「locale 没生效」与「mo 不在 KLocalizedString 查找路径」两类根因
    fail "zh_CN 环境徽标取 po 译文" \
      "实测: $(printf '%s' "$ZH_OUTPUT" | grep -oE 'BMW_KCM_SWITCH_BADGE=[^ ]+' | head -1); locale警告=$(printf '%s' "$ZH_OUTPUT" | grep -c 'Detected locale'); QML_LOADED=$(printf '%s' "$ZH_OUTPUT" | grep -c 'BMW_KCM_QML_LOADED'); mo_user=$([ -f "$HOME/.local/share/locale/zh_CN/LC_MESSAGES/kcm_burnwindow.mo" ] && echo Y || echo N); mo_sys=$([ -f /usr/share/locale/zh_CN/LC_MESSAGES/kcm_burnwindow.mo ] && echo Y || echo N)"
  fi
  if printf '%s' "$ZH_OUTPUT" | grep -q 'text=全不选'; then
    pass "zh_CN 环境全选按钮取 po 译文（text=全不选）"
  else
    fail "zh_CN 环境全选按钮取 po 译文" "未匹配 text=全不选"
  fi
  # 参数名动态 msgid：Duration 的显示标签在中文环境应为 po 译文「时长」
  if printf '%s' "$ZH_OUTPUT" | grep -q 'BMW_KCM_PARAM_LABEL kwin6_effect_fire Duration 时长'; then
    pass "zh_CN 环境参数名取 po 译文（Duration→时长）"
  else
    fail "zh_CN 环境参数名取 po 译文" "实测: $(printf '%s' "$ZH_OUTPUT" | grep -oE 'BMW_KCM_PARAM_LABEL kwin6_effect_fire Duration .*' | head -1)"
  fi
fi

# ---------------------------------------------------------------- 环境恢复
echo
echo "恢复环境：还原/移除测试期间写入的系统 KCM"
restore_kcm

# ---- 断言：测试开始前已存在的 KCM 必须原样保留（M-2）----
echo "=== test_preexisting_kcm_is_preserved ==="
if [ -n "$PRESET_FILE" ]; then
  if cmp -s "$PRESET_FILE" "$KCM_DEST" 2>/dev/null; then
    pass "测试开始前已存在的 KCM 被原样保留（未被删除）"
  else
    RC=1
    fail "测试开始前已存在的 KCM 被原样保留（未被删除）" \
      "目标不存在或内容与预置不符（正式安装的 KCM 会这样丢失）"
  fi
elif [ "$KCM_WAS_PRESENT" -eq 1 ]; then
  if cmp -s "$KCM_BACKUP_DIR/kcm_burnwindow.so" "$KCM_DEST" 2>/dev/null; then
    pass "测试开始前已存在的 KCM 被原样保留（未被删除）"
  else
    RC=1
    fail "测试开始前已存在的 KCM 被原样保留（未被删除）" "未还原备份"
  fi
else
  skip "测试开始前已存在的 KCM 被原样保留" "测试开始时目标不存在，且未成功预置"
fi

# 清理占位文件，使系统状态回到测试开始前
cleanup_preset
NOW_PRESENT=0
[ -e "$KCM_DEST" ] && NOW_PRESENT=1
assert_eq "$NOW_PRESENT" "$KCM_INITIAL_PRESENT" "测试后系统 KCM 存在状态与测试前一致（净影响为零）"

teardown

echo "=== test_param_widget_type_fallbacks ==="
# P1-5 + spec 4.3：参数控件按类型兜底。上游 main.xml 实测无 <min>/<max> 标签
# （2026-09-29 全池 grep 0 文件）→ spec「min/max 来自 main.xml」无数据源，
# 降级为类型相关固定值域：Double 必须允许负值（Tilt=-0.3 / Shift=-0.05 的
# 负默认被 from: 0 钳为 0，onValueModified 触发即写回 0 覆盖负值）；
# Int / String 分支按 spec 4.3（Int → SpinBox、String → TextField）补齐。
QML_FILE="$KCM_SRC/ui/main.qml"
if grep -A4 'type === "Double"' "$QML_FILE" | grep -qE 'from: -[0-9]'; then
  pass "Double 控件允许负值（from < 0）"
else
  fail "Double 控件允许负值（from < 0）" "DoubleSpinBox from 仍非负或缺失"
fi
if grep -q 'type === "Int"' "$QML_FILE"; then
  pass "Int 类型有控件分支（spec 4.3）"
else
  fail "Int 类型有控件分支（spec 4.3）" '未找到 type === "Int"'
fi
if grep -q 'type === "String"' "$QML_FILE"; then
  pass "String 类型有控件分支（spec 4.3）"
else
  fail "String 类型有控件分支（spec 4.3）" '未找到 type === "String"'
fi
if grep -q 'min/max' "$QML_FILE"; then
  pass "控件值域含 min/max 降级依据注释"
else
  fail "控件值域含 min/max 降级依据注释" "未找到降级说明"
fi

echo
echo "结果: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
