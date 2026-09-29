#!/usr/bin/env bash
# install.sh 首装流程测试 —— bash tests/test_install.sh
#
# 隔离策略：--prefix 把**所有写入路径**重定向到临时目录，包括特效目录
# prefix/effects/（因此每个用例先从真实 ~/.local/share/kwin/effects/ 预置
# 19 个特效的 fixture，池成员清单从中现场提取）。
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$ROOT/install.sh"
REAL_EFFECTS="$HOME/.local/share/kwin/effects"

PASS=0
FAIL=0
SKIP=0
OUTPUT=""
RC=0

setup() {
  PREFIX="$(mktemp -d /tmp/bmw-install-test.XXXXXX)"
  mkdir -p "$PREFIX/effects"
  local d id
  for d in "$REAL_EFFECTS"/*/; do
    id="$(basename "$d")"
    mkdir -p "$PREFIX/effects/$id/contents/code"
    cp "$d/metadata.json" "$PREFIX/effects/$id/" 2>/dev/null || true
    cp "$d/contents/code/main.js" "$PREFIX/effects/$id/contents/code/" 2>/dev/null || true
  done
}

teardown() {
  [ -n "${PREFIX:-}" ] && rm -rf "$PREFIX"
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
  printf '  ✖ %s\n    %s\n    退出码=%s\n    输出尾部: %s\n' \
    "$1" "$2" "$RC" "$(printf '%s' "$OUTPUT" | tail -3 | tr '\n' '|')"
}

pass() {
  PASS=$((PASS + 1))
  printf '  ✔ %s\n' "$1"
}

assert_eq() {  # assert_eq <actual> <expected> <label>
  if [ "$1" = "$2" ]; then pass "$3"; else fail "$3" "期望 [$2] 实际 [$1]"; fi
}
assert_not_exists() {
  if [ ! -e "$1" ]; then pass "$2"; else fail "$2" "文件不应存在: $1"; fi
}
assert_exists() {
  if [ -e "$1" ]; then pass "$2"; else fail "$2" "文件应存在: $1"; fi
}
assert_output_contains() {
  case "$OUTPUT" in
    *"$1"*) pass "$2" ;;
    *) fail "$2" "输出应包含 [$1]" ;;
  esac
}
assert_empty() {
  if [ -z "$1" ]; then pass "$2"; else fail "$2" "应为空，实际 [$1]"; fi
}
assert_exit_code_nonzero() {
  if [ "$RC" -ne 0 ]; then pass "$1"; else fail "$1" "退出码应非 0"; fi
}
assert_exit_code_zero() {
  if [ "$RC" -eq 0 ]; then pass "$1"; else fail "$1" "退出码应为 0，实际 $RC"; fi
}

echo "=== test_dry_run_writes_nothing ==="
setup
run bash "$INSTALL" --dry-run --prefix "$PREFIX"
assert_exit_code_zero "--dry-run 退出码为 0"
assert_not_exists "$PREFIX/burn-window-randomrc" "--dry-run 不写配置"
assert_not_exists "$PREFIX/kwinrc" "--dry-run 不写 kwinrc"
assert_output_contains "kwin6_effect_fire" "--dry-run 打印池成员"
teardown

echo "=== test_first_run_writes_config_with_all_19_pool_members ==="
setup
run bash "$INSTALL" --prefix "$PREFIX" --skip-sudo --skip-build --skip-kwinrc
assert_exit_code_zero "首装退出码为 0"
CFG="$PREFIX/burn-window-randomrc"
assert_exists "$CFG" "配置文件已写入"
if [ -f "$CFG" ]; then
  POOL="$(kreadconfig6 --file "$CFG" --group General --key Pool 2>/dev/null)"
  assert_eq "$(printf '%s' "$POOL" | tr ',' '\n' | grep -c .)" "19" "Pool 含 19 个成员"
  BL="$(kreadconfig6 --file "$CFG" --group General --key Blacklist 2>/dev/null)"
  assert_empty "$BL" "Blacklist 默认为空"
  AS="$(kreadconfig6 --file "$CFG" --group General --key ApplyScript 2>/dev/null)"
  if [ -n "$AS" ]; then pass "ApplyScript 已写入"; else fail "ApplyScript 已写入" "为空"; fi
fi
teardown

echo "=== test_sudo_step_is_last_and_failure_aborts ==="
setup
run bash "$INSTALL" --prefix "$PREFIX" --skip-build --fail-sudo
assert_exit_code_nonzero "sudo 失败 → 退出码非 0"
assert_not_exists "$PREFIX/burn-window-randomrc" "sudo 失败 → 不写配置（半安装不留标志）"
teardown

echo "=== test_kwinrc_enabled_written_for_all_19 ==="
setup
run bash "$INSTALL" --prefix "$PREFIX" --skip-sudo --skip-build
assert_exit_code_zero "退出码为 0"
if [ -f "$PREFIX/kwinrc" ]; then
  assert_eq "$(grep -c 'kwin6_effect_.*Enabled=true' "$PREFIX/kwinrc")" "19" "kwinrc 写入 19 个 Enabled=true"
else
  fail "kwinrc 写入 19 个 Enabled=true" "kwinrc 不存在"
fi
teardown

echo "=== test_existing_kwinrc_backed_up_before_rewrite ==="
setup
printf '[Plugins]\nsomeOldKey=true\n' > "$PREFIX/kwinrc"
run bash "$INSTALL" --prefix "$PREFIX" --skip-sudo --skip-build
assert_exit_code_zero "退出码为 0"
BAK="$(ls "$PREFIX"/kwinrc.bak.* 2>/dev/null | head -1)"
if [ -n "$BAK" ]; then
  pass "改写前已创建备份"
  assert_eq "$(grep -c 'someOldKey=true' "$BAK")" "1" "备份保留原有键（未被覆盖）"
else
  fail "改写前已创建备份" "未找到 kwinrc.bak.*"
fi
teardown

echo "=== test_build_failure_writes_nothing ==="
setup
run bash "$INSTALL" --prefix "$PREFIX" --fail-build
assert_exit_code_nonzero "构建失败 → 退出码非 0"
assert_not_exists "$PREFIX/burn-window-randomrc" "构建失败 → 不写配置"
assert_not_exists "$PREFIX/kwinrc" "构建失败 → 不改 kwinrc"
teardown

echo "=== test_injects_arbiter_into_all_19_effects ==="
setup
run bash "$INSTALL" --prefix "$PREFIX" --skip-sudo --skip-build --skip-kwinrc
assert_exit_code_zero "退出码为 0"
INJECTED=0
for f in "$PREFIX"/effects/*/contents/code/main.js; do
  grep -q "BMW_ARBITER_BEGIN" "$f" && INJECTED=$((INJECTED + 1))
done
assert_eq "$INJECTED" "19" "19 个 main.js 均被注入"
assert_eq "$(ls "$PREFIX"/effects/*/contents/code/main.js.orig 2>/dev/null | wc -l)" "19" "19 份 .orig 备份齐全"
teardown

echo
echo "结果: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
