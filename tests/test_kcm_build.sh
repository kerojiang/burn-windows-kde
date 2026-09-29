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

setup() {
  BUILD="$(mktemp -d /tmp/bmw-kcm-build.XXXXXX)"
  PREFIX="$(mktemp -d /tmp/bmw-kcm-prefix.XXXXXX)"
}

teardown() {
  [ -n "${BUILD:-}" ] && rm -rf "$BUILD"
  [ -n "${PREFIX:-}" ] && rm -rf "$PREFIX"
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

# ============================================================ 1. 构建
echo "=== test_build_produces_so ==="
setup
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
  # applyOutput 必须非空：/bin/false 退出码 1，KCM 应给出失败描述
  if printf '%s' "$OUTPUT" | grep -q "BMW_KCM_DIAG_APPLY_OUTPUT=.\{1,\}"; then
    pass "apply 失败信息非空（/bin/false 退出码 1 被上报）"
  else
    fail "apply 失败信息非空（/bin/false 退出码 1 被上报）" "applyOutput 为空"
  fi
fi

# ============================================================ 环境恢复
echo
echo "恢复环境：移除测试装入的系统 KCM"
if sudo_available; then
  sudo_cmd rm -f "$KCM_DEST" && echo "  已删除 $KCM_DEST"
else
  echo "  sudo 凭证不可用，保留 $KCM_DEST（下次运行会覆盖）"
fi
teardown

echo
echo "结果: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
