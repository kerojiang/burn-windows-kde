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
    mkdir -p "$PREFIX/effects/$id/contents/code"
    cp "$d/metadata.json" "$PREFIX/effects/$id/" 2>/dev/null || true
    # fixture 必须是上游纯净态（真实环境 e2e 首装后已注入，inject.py 会 exit 2）
    src="$d/contents/code/main.js.orig"
    [ -e "$src" ] || src="$d/contents/code/main.js"
    cp "$src" "$PREFIX/effects/$id/contents/code/main.js" 2>/dev/null || true
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
  env BURN_WINDOW_CONFIG="$CFG" BURN_WINDOW_EFFECTS="$PREFIX/effects" \
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

# ================================================================ 2. checked 反映黑名单
echo "=== test_checkbox_checked_reflects_blacklist ==="
kwriteconfig6 --file "$CFG" --group General --key Blacklist "kwin6_effect_fire"
launch_and_collect
assert_contains "BMW_KCM_ITEM kwin6_effect_fire checked=true" "黑名单中的 fire → checked=true"
assert_contains "BMW_KCM_ITEM kwin6_effect_doom checked=false" "未入黑名单的 doom → checked=false"

# ================================================================ 3. 19 项全部渲染
echo "=== test_all_19_items_rendered ==="
POOL_COUNT="$(kreadconfig6 --file "$CFG" --group General --key Pool | tr ',' '\n' | grep -c .)"
ITEM_COUNT="$(printf '%s' "$OUTPUT" | grep -c 'BMW_KCM_ITEM ')"
assert_eq "$ITEM_COUNT" "$POOL_COUNT" "渲染项数 == Pool 长度 ($POOL_COUNT)"
assert_eq "$ITEM_COUNT" "19" "渲染项数 == 19"

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

echo
echo "结果: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
