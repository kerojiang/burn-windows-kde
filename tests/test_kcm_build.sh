#!/usr/bin/env bash
# KCM 构建/加载/apply 诊断测试 —— bash tests/test_kcm_build.sh
#
# 用例 2、3 需要把 .so 装入系统路径（唯一需提权的步骤）。凭据通过 sudo 凭证缓存
# 提供（跑本脚本前由运行者执行 sudo -v），缓存不可用时标记 SKIP 而非假阴性通过。
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KCM_SRC="$ROOT/kcm"
KCM_DEST="/usr/lib/qt6/plugins/plasma/kcms/systemsettings/kcm_burnwindow.so"
KWIN_INTERFACE="org.kde.kwin.Effects"

PASS=0
FAIL=0
SKIP=0
OUTPUT=""
RC=0
BUILD=""
PREFIX=""
# ---- 保护测试开始前已存在的系统 KCM（M-2）----
# 旧版：进入时无条件 install 覆盖、退出时无条件 rm —— 用户经 install.sh 正式
# 安装的 KCM 会在跑完测试后从系统设置消失。修复：进入时先快照，退出时还原。
KCM_BACKUP_DIR=""     # 进入测试时 KCM_DEST 的内容快照
KCM_WAS_PRESENT=0     # 进入测试时目标是否已存在
KCM_SNAPSHOT_DONE=0   # 快照是否已执行 —— 未快照时 restore 必须不动目标
KCM_RESTORED=0        # 恢复动作只执行一次（显式路径与 trap 兜底共用）
PRESET_FILE=""        # 用例 0 预置的占位 KCM（断言"原样保留"的比对源）
KCM_INITIAL_PRESENT=0 # 预置动作之前的初始状态（断言"净影响为零"用）

setup() {
  BUILD="$(mktemp -d /tmp/bmw-kcm-build.XXXXXX)"
  PREFIX="$(mktemp -d /tmp/bmw-kcm-prefix.XXXXXX)"
}

teardown() {
  [ -n "${BUILD:-}" ] && rm -rf "$BUILD"
  [ -n "${PREFIX:-}" ] && rm -rf "$PREFIX"
  [ -n "${KCM_BACKUP_DIR:-}" ] && rm -rf "$KCM_BACKUP_DIR"
}

run() {
  set +e
  OUTPUT="$("$@" 2>&1)"
  RC=$?
  # 恢复脚本原状态（原为 set -u，无 errexit）。误写成 set -e 会让 run 之后
  # 任何返回非 0 的裸命令直接静默退出脚本 —— 此前 test_kcm_build.sh 因此
  # 在 `wait $KPID`（子进程已被 KILL，返回 137）处中断。
  set +e
}

fail() {
  FAIL=$((FAIL + 1))
  printf '  ✖ %s\n    %s\n    退出码=%s\n    输出: %s\n' \
    "$1" "$2" "$RC" "$(printf '%s' "$OUTPUT" | tail -4 | tr '\n' '|')"
}
pass() { PASS=$((PASS + 1)); printf '  ✔ %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf '  ⊘ %s —— %s\n' "$1" "$2"; }

assert_exists() {
  if [ -e "$1" ]; then pass "$2"; else fail "$2" "应存在: $1"; fi
}
assert_contains() {
  case "$OUTPUT" in
    *"$1"*) pass "$2" ;;
    *) fail "$2" "应包含 [$1]" ;;
  esac
}
assert_exit_code_zero() {
  if [ "$RC" -eq 0 ]; then pass "$1"; else fail "$1" "退出码应为 0，实际 $RC"; fi
}
assert_eq() { # assert_eq <actual> <expected> <label>
  if [ "$1" = "$2" ]; then pass "$3"; else fail "$3" "期望 [$2] 实际 [$1]"; fi
}

sudo_available() { sudo -n true 2>/dev/null || [ -n "${SUDO_PASSWORD:-}" ]; }

# 提权通道：优先用已有凭证缓存；缓存对子脚本无效时（本环境实测
# `sudo -n` 仅对与建缓存进程同父进程的调用生效，bash 子脚本返回 rc=1），
# 回退到运行者通过 SUDO_PASSWORD 注入的凭据 —— 凭据只经环境变量传入，
# 不硬编码进测试代码；两者皆无时调用方标记 SKIP。
sudo_cmd() {
  if sudo -n true 2>/dev/null; then
    sudo "$@"
  elif [ -n "${SUDO_PASSWORD:-}" ]; then
    printf '%s\n' "$SUDO_PASSWORD" | sudo -S "$@"
  else
    echo "sudo 凭据不可用（缓存未被子脚本继承，且未提供 SUDO_PASSWORD）" >&2
    return 1
  fi
}

# ---- 系统 KCM 的快照与还原（M-2）----
# 进入测试时对 KCM_DEST 做一次快照；退出时原样还原。这样"本次为新装"才删除，
# "进入时已存在"（用户正式安装 / 用例 0 的占位）一律还原 —— 跑测试不再让
# 用户已装的 KCM 从系统设置里消失。
snapshot_kcm() {
  KCM_SNAPSHOT_DONE=1
  [ "${KCM_WAS_PRESENT:-0}" -eq 1 ] && return 0
  [ -e "$KCM_DEST" ] || return 0
  KCM_BACKUP_DIR="$(mktemp -d /tmp/bmw-kcm-snap.XXXXXX)"
  if cp "$KCM_DEST" "$KCM_BACKUP_DIR/kcm_burnwindow.so" 2>/dev/null \
     && [ -s "$KCM_BACKUP_DIR/kcm_burnwindow.so" ]; then
    KCM_WAS_PRESENT=1
  else
    # 快照失败时不冒充"已备份"——宁可退出时不动目标，也不删掉无法还原的文件
    echo "  快照失败，退出时不删除 $KCM_DEST" >&2
    rm -rf "$KCM_BACKUP_DIR"
    KCM_BACKUP_DIR=""
    KCM_WAS_PRESENT=1
  fi
}

restore_kcm() {
  [ "${KCM_RESTORED:-0}" -eq 1 ] && return 0
  # 从未快照 = 还没走到"记录初始状态"那一步（脚本极早失败）。
  # 此时无法区分"目标是用户正式安装"还是"本次新装"，一律不动 ——
  # 删错的代价（用户正式安装消失）远大于留一个占位文件。
  [ "${KCM_SNAPSHOT_DONE:-0}" -eq 1 ] || return 0
  if ! sudo_available; then
    echo "  sudo 凭证不可用，保留 $KCM_DEST（快照: ${KCM_WAS_PRESENT:-0}）"
    return 0
  fi
  KCM_RESTORED=1
  if [ "${KCM_WAS_PRESENT:-0}" -eq 0 ]; then
    # 快照明确记录"进入时目标不存在" = 本次为新装，删除才安全
    sudo_cmd rm -f "$KCM_DEST" && echo "  已删除 $KCM_DEST"
  elif [ -f "$KCM_BACKUP_DIR/kcm_burnwindow.so" ]; then
    if sudo_cmd install -D -m 0644 "$KCM_BACKUP_DIR/kcm_burnwindow.so" "$KCM_DEST"; then
      echo "  已还原测试开始前的 KCM: $KCM_DEST"
    else
      echo "  还原失败: $KCM_DEST（备份仍在 $KCM_BACKUP_DIR）" >&2
      KCM_RESTORED=0
    fi
  else
    # 进入时存在但快照没拿到内容 —— 无法还原，只能原样保留，绝不删除
    echo "  快照内容缺失，保留 $KCM_DEST 不动" >&2
  fi
}

# 占位文件是本测试自己放的，最终必须清掉，让系统回到 KCM_INITIAL_PRESENT
# 描述的状态；若初始就已存在（用户正式安装）则 PRESET_FILE 为空，本函数不动。
KCM_PRESET_CLEANED=0
cleanup_preset() {
  [ "${KCM_PRESET_CLEANED:-0}" -eq 1 ] && return 0
  [ -n "${PRESET_FILE:-}" ] || return 0
  KCM_PRESET_CLEANED=1
  sudo_available || return 0
  sudo_cmd rm -f "$KCM_DEST" >/dev/null 2>&1 || true
}

# 提前 exit 的路径（构建失败/提权失败）也必须还原，否则占位文件会留在系统路径
trap 'restore_kcm; cleanup_preset' EXIT

setup   # 占位文件落在 BUILD 临时目录里，必须先于预置

# ============================================================ 0. 保护已装产物
# 放在构建之前：构建失败走 exit 1 时，快照必须已经存在，否则 restore 会把
# "从未快照"误判成"本次新装"并删掉用户正式安装的 KCM。
echo "=== test_preexisting_kcm_is_preserved ==="
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

# ============================================================ 1. 构建
echo "=== test_build_produces_so ==="
run cmake -S "$KCM_SRC" -B "$BUILD" -G Ninja
assert_exit_code_zero "CMake configure"
run cmake --build "$BUILD"
assert_exit_code_zero "CMake build"
assert_exists "$BUILD/bin/plasma/kcms/systemsettings/kcm_burnwindow.so" "产物 .so 已生成"
SO="$BUILD/bin/plasma/kcms/systemsettings/kcm_burnwindow.so"

# ============================================================ 2. 安装并被 systemsettings 发现
echo "=== test_kcmshell6_loads_by_name ==="
if [ ! -f "$SO" ]; then
  skip "系统级安装与按名加载" "构建产物缺失，前置用例已失败"
elif ! sudo_available; then
  skip "系统级安装与按名加载" "sudo 凭证缓存不可用（先执行 sudo -v），按 plan 要求标记 SKIP 而非假阴性通过"
else
  run sudo_cmd install -D -m 0644 "$SO" "$KCM_DEST"
  assert_exit_code_zero "安装到系统路径"

  run systemsettings --list
  assert_exit_code_zero "systemsettings --list 退出码 0"
  assert_contains "kcm_burnwindow" "不带 QT_PLUGIN_PATH 也能被发现"

  # 实际 dlopen：启动 kcmshell6 后检查 /proc/<pid>/maps
  kcmshell6 kcm_burnwindow >/dev/null 2>&1 &
  KPID=$!
  sleep 4
  if grep -q "kcm_burnwindow.so" "/proc/$KPID/maps" 2>/dev/null; then
    pass "kcmshell6 按名加载并 dlopen 到系统路径"
  else
    fail "kcmshell6 按名加载并 dlopen 到系统路径" "/proc/$KPID/maps 未见 kcm_burnwindow.so"
  fi
  # kcmshell6 若不响应 TERM，裸 wait 会无限等待 —— 先 TERM，再兜底 KILL
  kill "$KPID" 2>/dev/null
  sleep 1
  kill -9 "$KPID" 2>/dev/null
  wait "$KPID" 2>/dev/null
fi

# ============================================================ 3. apply 失败时把 stderr 报出来
echo "=== test_apply_failure_reports_error ==="
if [ ! -f "$KCM_DEST" ]; then
  skip "apply 失败诊断输出" "KCM 未安装到系统路径（前置用例 SKIP/失败）"
elif ! grep -qa "kcm_burnwindow" "$KCM_DEST" 2>/dev/null; then
  # 目标文件不是本项目产物（用例 2 被 skip，系统路径上仍是用例 0 的占位文件）
  skip "apply 失败诊断输出" "系统路径 KCM 非本次构建产物"
elif ! command -v kcmshell6 >/dev/null 2>&1; then
  skip "apply 失败诊断输出" "kcmshell6 不可用"
else
  cat > "$PREFIX/burn-window-randomrc" <<CFG
[General]
Pool=kwin6_effect_fire
Blacklist=
ApplyScript=/bin/false
CFG
  # 诊断模式：KCM 构造后自动执行一次 apply，把结果写到 stderr 后退出
  # -k 5：TERM 后 5 秒仍不退出则 KILL，避免 GNU timeout 默认的无限等待
  run env BURN_WINDOW_CONFIG="$PREFIX/burn-window-randomrc" \
          BMW_KCM_DIAG_APPLY=1 \
          timeout -k 5 30 kcmshell6 kcm_burnwindow
  assert_exit_code_zero "诊断模式正常退出（未挂起）"
  assert_contains "BMW_KCM_DIAG_APPLY_OUTPUT=" "诊断输出已写出"
  # RF5「按钮状态恢复」（审查 M-6）：finishApply 是 applyRunning 的唯一收口，
  # 走不到它就会让状态停在 running。用诊断输出代替 GUI 操作。
  assert_contains "BMW_KCM_DIAG_APPLY_RUNNING=false" "apply 结束后 applyRunning 已归零（按钮状态恢复）"
  assert_contains "BMW_KCM_DIAG_APPLY_NEEDSSAVE=false" "apply 结束后 needsSave 回到基线（框架按钮可用性的驱动量已复位）"
  # applyOutput 必须非空：/bin/false 退出码 1，KCM 应给出失败描述
  if printf '%s' "$OUTPUT" | grep -q "BMW_KCM_DIAG_APPLY_OUTPUT=.\{1,\}"; then
    pass "apply 失败信息非空（/bin/false 退出码 1 被上报）"
  else
    fail "apply 失败信息非空（/bin/false 退出码 1 被上报）" "applyOutput 为空"
  fi
fi

# ============================================================ 环境恢复
echo
echo "恢复环境：还原/移除测试期间写入的系统 KCM"
restore_kcm

# ---- 断言：测试开始前已存在的 KCM 必须原样保留（M-2）----
echo "=== test_preexisting_kcm_is_preserved ==="
if [ -n "$PRESET_FILE" ]; then
  # 期望内容 = 用例 0 预置的占位文件：被覆盖后必须原样还原，而不是被删除
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

# 清理用例 0 的占位文件，使系统状态回到测试开始前
cleanup_preset
NOW_PRESENT=0
[ -e "$KCM_DEST" ] && NOW_PRESENT=1
assert_eq "$NOW_PRESENT" "$KCM_INITIAL_PRESENT" "测试后系统 KCM 存在状态与测试前一致（净影响为零）"

teardown

echo
echo "结果: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
