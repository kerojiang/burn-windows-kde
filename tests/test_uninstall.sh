#!/usr/bin/env bash
# 卸载脚本测试 —— bash tests/test_uninstall.sh
#
# 验收目标：完整卸载、不留任何记录。
# 全部在 prefix 中隔离执行（不触碰 ~/.config/kwinrc 与真实特效目录）；
# KCM 删除用 `BURN_WINDOW_KCM_DEST` 指向 prefix 内的假文件验证删除逻辑，
# 系统路径的提权删除另有 test_kcm_build.sh 的恢复步骤覆盖。
#
# 执行编排：一次安装 → dry-run 断言无副作用 → 放置假 KCM → 执行卸载 →
# 全部清理/还原/保留断言 → 二次卸载验幂等。
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_EFFECTS="$HOME/.local/share/kwin/effects"

PASS=0
FAIL=0
SKIP=0
OUTPUT=""
RC=0
PREFIX=""
TMPDIR_TEST=""
CFG=""
KWINRC=""
EFFECTS=""

# ---------------------------------------------------------------- helpers

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

assert_eq() { # 实际 期望 标签
  if [ "$1" = "$2" ]; then pass "$3"; else fail "$3" "期望 [$2] 实际 [$1]"; fi
}
assert_exists() { # 路径 标签
  if [ -e "$1" ]; then fail "$2" "应已删除但仍存在: $1"; else pass "$2"; fi
}
assert_absent_or_equal() { # 实际文件 期望文件 标签
  if cmp -s "$1" "$2"; then pass "$3"; else fail "$3" "内容不一致: $1"; fi
}

setup() {
  PREFIX="$(mktemp -d /tmp/bmw-uninstall-prefix.XXXXXX)"
  TMPDIR_TEST="$(mktemp -d /tmp/bmw-uninstall-tmp.XXXXXX)"
  CFG="$PREFIX/burn-window-randomrc"
  KWINRC="$PREFIX/kwinrc"
  EFFECTS="$PREFIX/effects"

  # 特效 fixture（与 test_install.sh 同一来源，不触碰真实目录）
  mkdir -p "$EFFECTS"
  # fixture 必须是"上游纯净"状态，且安装必须 --skip-build，两处缺一都会让
  # 还原断言失去意义（实测依据）：
  #   1. 真实目录的 main.js 处于已注入态（含 BMW_ARBITER_BEGIN），inject.py
  #      会因"已注入但缺 .orig"直接 exit 2（lib/inject.py 152-155 行）；
  #   2. 不加 --skip-build 时 install.sh 的 do_build 会 tar -xzf 覆盖
  #      EFFECTS_DIR（install.sh 133 行），fixture 被上游产物整体替换，
  #      此时保存的快照与卸载后的还原结果必然不一致。
  local d id src
  for d in "$REAL_EFFECTS"/*/; do
    [ -e "$d" ] || continue
    id="$(basename "$d")"
    mkdir -p "$EFFECTS/$id/contents/code"
    cp "$d/metadata.json" "$EFFECTS/$id/" 2>/dev/null || true
    # 优先取该特效的 .orig（注入前的纯净备份）；无备份时 main.js 即未注入态
    src="$d/contents/code/main.js.orig"
    [ -e "$src" ] || src="$d/contents/code/main.js"
    cp "$src" "$EFFECTS/$id/contents/code/main.js" 2>/dev/null || true
  done

  # 保存安装前的原始内容，供卸载后逐字节比较
  for m in "$EFFECTS"/*/contents/code/main.js; do
    [ -e "$m" ] || continue
    id="$(basename "$(dirname "$(dirname "$(dirname "$m")")")")"
    cp "$m" "$TMPDIR_TEST/orig_$id.js"
  done

  if grep -q 'BMW_ARBITER_BEGIN' "$TMPDIR_TEST"/orig_*.js 2>/dev/null; then
    fail "setup: fixture 必须是未注入态" "快照仍含 BMW_ARBITER_BEGIN"
    return 1
  fi

  # 非 BMW 的 kwinrc 条目：卸载不得误删用户已有配置
  kwriteconfig6 --file "$KWINRC" --group Windows --key BorderlessMaximizedWindows true
  kwriteconfig6 --file "$KWINRC" --group Effect-overrides --key kwin6_effect_dialogsEnabled false

  # 模拟完整安装：--skip-build 避免构建覆盖 fixture，--skip-sudo 跳过真 KCM
  run bash "$ROOT/install.sh" --prefix "$PREFIX" --skip-build --skip-sudo
  if [ "$RC" -ne 0 ]; then
    fail "setup: install.sh 安装失败" "退出码 $RC"
    return 1
  fi

  # 记录池成员：卸载后的 kwinrc 断言必须逐 id 检查 —— 不能用宽泛的
  # `kwin6_effect_.*Enabled` 统计，否则会把用例 6 放置的非池条目
  # kwin6_effect_dialogsEnabled 误算为未清除的 BMW 条目
  POOL_IDS="$(kreadconfig6 --file "$CFG" --group General --key Pool 2>/dev/null | tr ',' ' ')"
}

teardown() {
  [ -n "$PREFIX" ] && rm -rf "$PREFIX"
  [ -n "$TMPDIR_TEST" ] && rm -rf "$TMPDIR_TEST"
}

# ---------------------------------------------------------------- 前置

echo "=== 前置：安装 ==="
setup || { echo; echo "结果: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 1; }

N_EFFECTS="$(ls -d "$EFFECTS"/*/ 2>/dev/null | wc -l | tr -d ' ')"
INJECTED="$(grep -l 'BMW_ARBITER_BEGIN' "$EFFECTS"/*/contents/code/main.js 2>/dev/null | wc -l | tr -d ' ')"
ORIG_N="$(ls "$EFFECTS"/*/contents/code/main.js.orig 2>/dev/null | wc -l | tr -d ' ')"
echo "  特效 $N_EFFECTS 个 / 已注入 $INJECTED / .orig $ORIG_N"

# ================================================================ 1. dry-run 无副作用
echo "=== test_uninstall_dry_run_changes_nothing ==="
run bash "$ROOT/uninstall.sh" --prefix "$PREFIX" --skip-sudo --dry-run
if [ "$RC" -eq 0 ]; then
  pass "--dry-run 退出码 0"
else
  fail "--dry-run 退出码 0" "实际 $RC"
fi

AFTER_DRY_INJECT="$(grep -l 'BMW_ARBITER_BEGIN' "$EFFECTS"/*/contents/code/main.js 2>/dev/null | wc -l | tr -d ' ')"
AFTER_DRY_ORIG="$(ls "$EFFECTS"/*/contents/code/main.js.orig 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "$AFTER_DRY_INJECT" "$INJECTED" "dry-run 后注入数不变"
assert_eq "$AFTER_DRY_ORIG" "$ORIG_N" "dry-run 后 .orig 数不变"
if [ -f "$CFG" ]; then pass "dry-run 后配置仍在"; else fail "dry-run 后配置仍在" "配置被删除"; fi
if grep -q 'kwin6_effect_fireEnabled' "$KWINRC" 2>/dev/null; then
  pass "dry-run 后 kwinrc BMW 条目仍在"
else
  fail "dry-run 后 kwinrc BMW 条目仍在" "条目被移除"
fi

# ================================================================ 2. 假 KCM（验证删除逻辑，无需提权）
echo "=== test_uninstall_removes_kcm ==="
FAKE_KCM="$PREFIX/kcm_burnwindow.so"
: > "$FAKE_KCM"
export BURN_WINDOW_KCM_DEST="$FAKE_KCM"

# ================================================================ 3. 执行卸载
echo
echo "=== 执行 uninstall.sh ==="
run bash "$ROOT/uninstall.sh" --prefix "$PREFIX" --skip-sudo
if [ "$RC" -eq 0 ]; then
  pass "卸载退出码 0"
else
  fail "卸载退出码 0" "实际 $RC"
fi
echo "  --- 卸载输出 ---"
printf '%s\n' "$OUTPUT" | sed 's/^/    /'

# ================================================================ 4. 全部痕迹清除
echo "=== test_uninstall_removes_all_install_artifacts ==="

LEFT_INJECT="$(grep -l 'BMW_ARBITER_BEGIN' "$EFFECTS"/*/contents/code/main.js 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "$LEFT_INJECT" "0" "无残留注入代码"

assert_eq "$(ls "$EFFECTS"/*/contents/code/main.js.orig 2>/dev/null | wc -l | tr -d ' ')" "0" ".orig 备份已全部删除"

# 特效目录本身是 install.sh 经 tar 解包的产物（install.sh:133，含
# metadata.json / shader / locale 数千文件），必须随卸载整体删除 ——
# 只还原 main.js 不删目录时，"不留任何记录"不成立
DIRS_LEFT=""
for id in $POOL_IDS; do
  [ -n "$id" ] || continue
  [ -d "$EFFECTS/$id" ] && DIRS_LEFT="$DIRS_LEFT $id"
done
if [ -z "$DIRS_LEFT" ]; then
  pass "池成员特效目录已全部删除（不留任何记录）"
else
  fail "池成员特效目录已全部删除（不留任何记录）" "残留:$DIRS_LEFT"
fi

assert_exists "$CFG" "配置文件已删除"
assert_exists "$PREFIX/burn-window-apply-config.sh" "apply 脚本已删除"
assert_exists "$PREFIX/libexec" "libexec 目录已删除（inject.py + arbiter.js）"
assert_exists "$FAKE_KCM" "KCM 产物已删除"

LEFT_KEYS=""
for id in $POOL_IDS; do
  [ -n "$id" ] || continue
  v="$(kreadconfig6 --file "$KWINRC" --group Plugins --key "${id}Enabled" 2>/dev/null)"
  [ -n "$v" ] && LEFT_KEYS="$LEFT_KEYS ${id}Enabled=$v"
done
if [ -z "$LEFT_KEYS" ]; then
  pass "kwinrc 中池内 19 个 Enabled 条目已全部移除"
else
  fail "kwinrc 中池内 19 个 Enabled 条目已全部移除" "残留:$LEFT_KEYS"
fi

assert_eq "$(ls "$KWINRC".bak.* 2>/dev/null | wc -l | tr -d ' ')" "0" "kwinrc 备份已删除（不留任何记录）"

# ================================================================ 5. 还原逐字节一致
echo "=== test_uninstall_restores_main_js_bit_exact ==="
MISMATCH=""
for orig in "$TMPDIR_TEST"/orig_*.js; do
  [ -e "$orig" ] || continue
  id="$(basename "$orig")"; id="${id#orig_}"; id="${id%.js}"
  # 目录已随卸载整体删除 = 无残留风险，无需逐字节比对；
  # 目录仍在（删除失败/未实现）时才要求 main.js 存在且逐字节一致
  [ -d "$EFFECTS/$id" ] || continue
  cur="$EFFECTS/$id/contents/code/main.js"
  if [ ! -e "$cur" ]; then
    MISMATCH="$MISMATCH $id(缺失)"
  elif ! cmp -s "$orig" "$cur"; then
    MISMATCH="$MISMATCH $id"
  fi
done
if [ -z "$MISMATCH" ]; then
  pass "全部 main.js 还原为安装前的逐字节原内容"
else
  fail "全部 main.js 还原为安装前的逐字节原内容" "不一致:$MISMATCH"
fi

# ================================================================ 6. 不误删用户配置
echo "=== test_uninstall_preserves_foreign_kwinrc_entries ==="
V1="$(kreadconfig6 --file "$KWINRC" --group Windows --key BorderlessMaximizedWindows 2>/dev/null)"
assert_eq "$V1" "true" "保留非 BMW 条目 Windows/BorderlessMaximizedWindows"

V2="$(kreadconfig6 --file "$KWINRC" --group Effect-overrides --key kwin6_effect_dialogsEnabled 2>/dev/null)"
assert_eq "$V2" "false" "保留同前缀但非池内的 kwin6_effect_dialogsEnabled"

# ================================================================ 7. 幂等
echo "=== test_uninstall_idempotent ==="
run bash "$ROOT/uninstall.sh" --prefix "$PREFIX" --skip-sudo
if [ "$RC" -eq 0 ]; then
  pass "二次卸载仍退出码 0（幂等）"
else
  fail "二次卸载仍退出码 0（幂等）" "退出码 $RC"
fi
V3="$(kreadconfig6 --file "$KWINRC" --group Windows --key BorderlessMaximizedWindows 2>/dev/null)"
assert_eq "$V3" "true" "二次卸载后用户配置仍在"

# ---------------------------------------------------------------- 环境恢复
unset BURN_WINDOW_KCM_DEST
teardown

echo
echo "结果: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
