#!/usr/bin/env bash
# --apply-config 测试 —— bash tests/test_apply_config.sh
#
# 主测对象是**独立 apply 脚本**（配置 ApplyScript= 指向它，Task 5 的 KCM 通过
# QProcess 调用的正是它），install.sh --apply-config 作为手动入口另有等价性用例。
#
# 需要本机 KWin D-Bus 运行（用例 3 断言 19 个特效真实加载）；结束后统一卸载，
# 恢复会话原状。
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$ROOT/install.sh"
REAL_EFFECTS="$HOME/.local/share/kwin/effects"
KWIN_INTERFACE="org.kde.kwin.Effects"   # 实测：小写 kwin；org.kde.KWin 会报 No such interface

PASS=0
FAIL=0
OUTPUT=""
RC=0
PREFIX=""
CFG=""
MAIN=""
APPLY=""

setup() {
  PREFIX="$(mktemp -d /tmp/bmw-apply-test.XXXXXX)"
  CFG="$PREFIX/burn-window-randomrc"
  MAIN="$PREFIX/effects/kwin6_effect_fire/contents/code/main.js"
  APPLY="$PREFIX/burn-window-apply-config.sh"

  mkdir -p "$PREFIX/effects"
  local d id
  for d in "$REAL_EFFECTS"/*/; do
    id="$(basename "$d")"
    mkdir -p "$PREFIX/effects/$id/contents/code"
    cp "$d/metadata.json" "$PREFIX/effects/$id/" 2>/dev/null || true
    cp "$d/contents/code/main.js" "$PREFIX/effects/$id/contents/code/" 2>/dev/null || true
  done
  # 首装：生成配置 + 注入（黑名单为空）+ apply 脚本
  bash "$INSTALL" --prefix "$PREFIX" --skip-sudo --skip-build --skip-kwinrc >/dev/null 2>&1
}

teardown() {
  [ -n "${PREFIX:-}" ] && rm -rf "$PREFIX"
}

apply_config() {
  # 独立脚本通过环境变量接收路径（KCM 调用时不带参数，走默认 $HOME 路径）
  BURN_WINDOW_CONFIG="$CFG" \
  BURN_WINDOW_EFFECTS="$PREFIX/effects" \
  BURN_WINDOW_INJECT="$PREFIX/libexec/inject.py" \
    bash "$APPLY"
}

run() {
  set +e
  OUTPUT="$("$@" 2>&1)"
  RC=$?
  set -e
}

fail() {
  FAIL=$((FAIL + 1))
  printf '  ✖ %s\n    %s\n    退出码=%s\n    输出: %s\n' \
    "$1" "$2" "$RC" "$(printf '%s' "$OUTPUT" | tail -3 | tr '\n' '|')"
}
pass() { PASS=$((PASS + 1)); printf '  ✔ %s\n' "$1"; }

assert_eq() {
  if [ "$1" = "$2" ]; then pass "$3"; else fail "$3" "期望 [$2] 实际 [$1]"; fi
}
assert_exit_code_zero() {
  if [ "$RC" -eq 0 ]; then pass "$1"; else fail "$1" "退出码应为 0，实际 $RC"; fi
}
assert_exit_code_nonzero() {
  if [ "$RC" -ne 0 ]; then pass "$1"; else fail "$1" "退出码应非 0"; fi
}
assert_stderr_contains() {
  case "$OUTPUT" in
    *"$1"*) pass "$2" ;;
    *) fail "$2" "stderr 应包含 [$1]" ;;
  esac
}
assert_files_identical() {
  if cmp -s "$1" "$2"; then pass "$3"; else fail "$3" "两文件不一致: $1 vs $2"; fi
}
assert_file_contains() {
  if grep -qF -- "$2" "$1" 2>/dev/null; then pass "$3"; else fail "$3" "$1 应包含 [$2]"; fi
}
assert_not_timed_out() {
  if [ "$RC" -ne 124 ]; then pass "$1"; else fail "$1" "超时（timeout 退出码 124）"; fi
}

loaded_bmw_count() {
  qdbus6 org.kde.KWin /Effects "$KWIN_INTERFACE".loadedEffects 2>/dev/null \
    | tr ',' '\n' | grep -c 'kwin6_effect_' || true
}

echo "=== test_apply_rereads_blacklist_and_reinjects ==="
setup
kwriteconfig6 --file "$CFG" --group General --key Blacklist "kwin6_effect_fire"
run apply_config
assert_exit_code_zero "apply 退出码 0"
# 断言黑名单字面量进入注入块（不能只断言 effect id —— main.js 自身就含该字符串）
assert_file_contains "$MAIN" 'BMW_BLACKLIST = ["kwin6_effect_fire"]' "黑名单字面量已写入注入块"
teardown

echo "=== test_apply_is_idempotent ==="
setup
run apply_config
assert_exit_code_zero "首次 apply 退出码 0"
cp "$MAIN" "$PREFIX/first.js"
run apply_config
assert_exit_code_zero "第二次 apply 退出码 0"
assert_files_identical "$PREFIX/first.js" "$MAIN" "两次 apply 结果逐字节相同"
teardown

echo "=== test_apply_reloads_all_19_effects ==="
setup
run apply_config
assert_exit_code_zero "apply 退出码 0"
assert_eq "$(loaded_bmw_count)" "19" "19 个特效经 D-Bus 重载后处于加载状态"
teardown

echo "=== test_apply_is_non_interactive ==="
setup
# stdin 关闭 + 环境变量同样必须传入（否则脚本回退到 $HOME 默认路径）
BURN_WINDOW_CONFIG="$CFG" \
BURN_WINDOW_EFFECTS="$PREFIX/effects" \
BURN_WINDOW_INJECT="$PREFIX/libexec/inject.py" \
  run timeout 30 bash "$APPLY" < /dev/null
assert_exit_code_zero "stdin 关闭时退出码 0"
assert_not_timed_out "未挂起等待输入"
teardown

echo "=== test_apply_refuses_when_config_missing ==="
setup
cp "$MAIN" "$PREFIX/main.before"
rm -f "$CFG"
run apply_config
assert_exit_code_nonzero "配置缺失 → 退出码非 0"
assert_stderr_contains "配置文件不存在" "诊断写 stderr"
assert_files_identical "$PREFIX/main.before" "$MAIN" "main.js 未被改动（不静默用默认值覆盖）"
teardown

echo "=== test_install_apply_config_subcommand_matches_script ==="
setup
kwriteconfig6 --file "$CFG" --group General --key Blacklist "kwin6_effect_doom"
run bash "$INSTALL" --prefix "$PREFIX" --apply-config
assert_exit_code_zero "install.sh --apply-config 退出码 0"
assert_file_contains "$MAIN" 'BMW_BLACKLIST = ["kwin6_effect_doom"]' "子命令与独立脚本行为一致"
teardown

# ---------------------------------------------------------------- 环境恢复
echo
echo "恢复环境：卸载本轮测试加载的特效"
if command -v qdbus6 >/dev/null 2>&1; then
  for id in $(qdbus6 org.kde.KWin /Effects "$KWIN_INTERFACE".loadedEffects 2>/dev/null | tr ',' '\n' | grep 'kwin6_effect_'); do
    qdbus6 org.kde.KWin /Effects unloadEffect "$id" >/dev/null 2>&1 || true
  done
  echo "  剩余已加载 BMW 特效: $(loaded_bmw_count)"
fi

echo
echo "结果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
