#!/usr/bin/env bash
# --apply-config 测试 —— bash tests/test_apply_config.sh
#
# 主测对象是**独立 apply 脚本**（配置 ApplyScript= 指向它，Task 5 的 KCM 通过
# QProcess 调用的正是它），install.sh --apply-config 作为手动入口另有等价性用例。
#
# 需要本机 KWin D-Bus 运行（apply 脚本自身会 reload 特效）；本脚本本身
# 不查询、不 unload 真实 KWin —— 隔离约定：只有 test_e2e.sh 允许操作真实环境。
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$ROOT/install.sh"
REAL_EFFECTS="$HOME/.local/share/kwin/effects"

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
  local d id src
  for d in "$REAL_EFFECTS"/*/; do
    id="$(basename "$d")"
    mkdir -p "$PREFIX/effects/$id/contents/code"
    cp "$d/metadata.json" "$PREFIX/effects/$id/" 2>/dev/null || true
    # fixture 必须是上游纯净态（真实环境 e2e 首装后已注入，inject.py 会 exit 2）
    src="$d/contents/code/main.js.orig"
    [ -e "$src" ] || src="$d/contents/code/main.js"
    cp "$src" "$PREFIX/effects/$id/contents/code/main.js" 2>/dev/null || true
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
  # 恢复脚本原状态（原为 set -u，无 errexit）。误写成 set -e 会让 run 之后
  # 任何返回非 0 的裸命令直接静默退出脚本。
  set +e
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

# ---------------------------------------------------------------- 隔离自检
# 隔离约定：只有 test_e2e.sh 允许操作真实 KWin。本脚本不得出现真实 KWin 的
# D-Bus 名字 —— 否则"prefix 隔离"只是名义上的，用例会读到真实环境状态。
# 模式串用 printf 拼接，避免本行文本被 -F 自己命中。
echo "=== test_apply_config_never_addresses_real_kwin ==="
SELF="${BASH_SOURCE[0]}"
REAL_KWIN_BUS="$(printf 'org.%s.%s' 'kde' 'KWin')"
HITS="$(grep -F -c "$REAL_KWIN_BUS" "$SELF" || true)"
assert_eq "${HITS:-0}" "0" "测试脚本自身不含真实 KWin D-Bus 名字（隔离约定）"

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
# 不查真实 KWin：改读 apply 自身的诊断输出 —— 每次 reload 失败都会打到 stderr，
# 因此"零失败 + 报告完成"直接反映被测对象的行为，而非真实环境的既有状态
assert_stderr_contains "[apply-config] 完成" "apply 报告完成（黑名单已生效）"
RELOAD_FAIL="$(printf '%s\n' "$OUTPUT" | grep -c 'loadEffect 失败' || true)"
assert_eq "${RELOAD_FAIL:-0}" "0" "19 个特效 reload 无失败（读 apply stderr）"
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

echo "=== test_apply_reports_broken_metadata ==="
# 审查 M-5 第三处：生成的 apply 脚本原用 `python3 -c ... X-KDE-PluginKeyword`
# 且 `[ -n "$id" ] || continue` —— 缺 id 字段时静默跳过，与 extract_pool
# （吞异常）、do_inject（抛栈）三种结局不一致。必须报告并失败。
setup
printf '{"KPlugin":{"Name":"NoIdHere"}}' > "$PREFIX/effects/kwin6_effect_fire/metadata.json"
run apply_config
assert_exit_code_nonzero "缺 id 字段 → apply 退出码非 0（不静默跳过）"
assert_stderr_contains "[apply-config] 警告" "诊断写 stderr"
teardown

echo "=== test_install_apply_config_subcommand_matches_script ==="
setup
kwriteconfig6 --file "$CFG" --group General --key Blacklist "kwin6_effect_doom"
run bash "$INSTALL" --prefix "$PREFIX" --apply-config
assert_exit_code_zero "install.sh --apply-config 退出码 0"
assert_file_contains "$MAIN" 'BMW_BLACKLIST = ["kwin6_effect_doom"]' "子命令与独立脚本行为一致"
teardown

# 不做"卸载真实特效"的收尾：本轮只在 prefix 内改写文件，对真实 KWin 的
# 影响仅来自 apply 脚本自身的 unload+load（reload 后仍是加载态）。
# 旧版逐个 unloadEffect 会让真实会话的 19 个特效在测试后全部消失，
# 并直接把后续 test_e2e.sh 的前置检查（loaded == 19）打成 FAIL。

echo "=== test_apply_skips_third_party_effects ==="
# P1-1 apply 侧：第三方特效（合法 metadata 无锚点 / 缺 metadata）不得让
# apply 失败 —— 无 id 的目录不可能在池中，非池成员不送 inject.py；
# 但池成员注入失败必须保持严格（防修复放松真问题）。
setup
THIRD="$PREFIX/effects/kwin6_effect_thirdparty"
mkdir -p "$THIRD/contents/code"
printf '{"KPlugin":{"Id":"kwin6_effect_thirdparty","Name":"Third"}}' > "$THIRD/metadata.json"
printf '// 第三方：无 BMW 锚点\nfunction f() {}\n' > "$THIRD/contents/code/main.js"
run apply_config
assert_eq "$RC" "0" "有 id 无锚点的第三方不致 apply 失败"
if grep -q 'BMW_ARBITER_BEGIN' "$THIRD/contents/code/main.js" 2>/dev/null; then
  fail "第三方未被注入" "main.js 出现仲裁标记"
else
  pass "第三方未被注入"
fi

# 缺 metadata 的目录：无 id 不可能在池中 → 跳过不计失败
NOMETA="$PREFIX/effects/kwin6_effect_ghost"
mkdir -p "$NOMETA/contents/code"
printf '// ghost\n' > "$NOMETA/contents/code/main.js"
run apply_config
assert_eq "$RC" "0" "缺 metadata 的目录不致 apply 失败"

# 池成员（已在池中的 fire）锚点被破坏 → 注入失败仍必须 die（严格性保持）
printf 'function broken() {}\n' > "$MAIN"
run apply_config
if [ "$RC" -ne 0 ]; then
  pass "池成员注入失败仍报错（严格性保持）"
else
  fail "池成员注入失败仍报错（严格性保持）" "破坏锚点的池成员被静默放过"
fi
teardown

echo
echo "结果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
