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
assert_output_contains() { # 子串 标签
  case "$OUTPUT" in
    *"$1"*) pass "$2" ;;
    *) fail "$2" "输出应包含 [$1]" ;;
  esac
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
    # metadata 优先取 .orig：真实环境 patch 后 metadata.json 是改造态，
    # 只有 .orig 才是上游原文，还原断言才能与环境状态解耦（同 test_install）
    src="$d/metadata.json.orig"
    [ -e "$src" ] || src="$d/metadata.json"
    cp "$src" "$EFFECTS/$id/metadata.json" 2>/dev/null || true
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

  # 预置占位总开关条目（用户开过开关的场景）：占位不在池成员清单内，
  # 其 kwinrc 条目必须被卸载显式删除（D8/C5 对称）
  kwriteconfig6 --file "$KWINRC" --group Plugins --key kwin6_effect_bmw_randomEnabled true

  # 孤儿目录：含 metadata.json + .orig 但非池成员（install 之后创建，避开
  # 安装期一切遍历）。池成员目录会被卸载整体删除、还原效果不可观察，孤儿
  # 目录保留下来后，"metadata 还原"可逐字节断言，且验证还原独立于池清单。
  ORPHAN="$EFFECTS/orphan_not_in_pool"
  mkdir -p "$ORPHAN"
  printf '%s\n' '{"KPlugin": {"Id": "orphan_not_in_pool"}, "X-KWin-Internal": "true", "X-KWin-Exclusive-Category": "bmw-hidden"}' \
    > "$ORPHAN/metadata.json"
  printf '%s\n' '{"KPlugin": {"Id": "orphan_not_in_pool"}, "X-KWin-Exclusive-Category": "toplevel-open-close-animation"}' \
    > "$ORPHAN/metadata.json.orig"
  cp "$ORPHAN/metadata.json.orig" "$TMPDIR_TEST/orphan_meta.orig"

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
# 旧 systemsettings 落点同样放假文件：两入口必须都被清理（D8 单一入口）
FAKE_KCM_OLD="$PREFIX/kcm_burnwindow_old.so"
: > "$FAKE_KCM_OLD"
export BURN_WINDOW_KCM_DEST_OLD="$FAKE_KCM_OLD"

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
assert_exists "$FAKE_KCM_OLD" "KCM 旧 systemsettings 落点已删除（防双入口）"

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

# ================================================================ 4b. 占位与 metadata 对称清理（Task 5）
echo "=== test_uninstall_placeholder_and_metadata_symmetry ==="

# 卸载输出必须显式报告 metadata 还原（步骤执行证据，池成员目录已整体删除）
assert_output_contains "metadata.json（双改造撤销）" "卸载输出含 metadata 还原报告"

# 占位特效目录不在池成员清单内，必须显式删除（C5）
if [ -d "$EFFECTS/kwin6_effect_bmw_random" ]; then
  fail "占位特效目录已删除" "仍存在: $EFFECTS/kwin6_effect_bmw_random"
else
  pass "占位特效目录已删除"
fi

# 占位总开关 kwinrc 条目独立删除（setup 预置了 Enabled=true）
PH_KEY="$(kreadconfig6 --file "$KWINRC" --group Plugins --key kwin6_effect_bmw_randomEnabled 2>/dev/null)"
assert_eq "$PH_KEY" "" "kwinrc 占位条目已删除"

# 全目录扫描：19 池 + 孤儿的 metadata.json.orig 必须零残留
META_ORIG_N="$(ls "$EFFECTS"/*/metadata.json.orig 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "$META_ORIG_N" "0" "无 metadata.json.orig 残留"

# 孤儿目录（非池成员）不得被删，但 metadata 必须逐字节还原为 .orig 原文
if [ -d "$EFFECTS/orphan_not_in_pool" ]; then
  if cmp -s "$TMPDIR_TEST/orphan_meta.orig" "$EFFECTS/orphan_not_in_pool/metadata.json"; then
    pass "孤儿目录 metadata 逐字节还原（还原独立于池成员清单）"
  else
    fail "孤儿目录 metadata 逐字节还原" "内容与原文不一致"
  fi
else
  fail "孤儿目录 metadata 逐字节还原" "孤儿目录被误删（非池成员不应删除）"
fi

# 静态：KCM 默认落点必须是 kwin 新落点，且旧落点同样纳入删除
if grep -q 'BURN_WINDOW_KCM_DEST:-/usr/lib/qt6/plugins/kwin/effects/configs/kcm_burnwindow.so' "$ROOT/uninstall.sh"; then
  pass "uninstall KCM_DEST 默认值指向 kwin 新落点"
else
  fail "uninstall KCM_DEST 默认值指向 kwin 新落点" "未找到新落点字面定义"
fi
if grep -q 'KCM_DEST_OLD' "$ROOT/uninstall.sh"; then
  pass "uninstall 含旧落点清理（KCM_DEST_OLD）"
else
  fail "uninstall 含旧落点清理（KCM_DEST_OLD）" "未找到 KCM_DEST_OLD"
fi

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

# ================================================================ 8. prefix 路径闸
echo "=== test_uninstall_prefix_rejects_root_and_home ==="
# 审查 M-3：uninstall.sh 原 41 行只判 --prefix 非空、215 行直接 rm -rf
# "$LIBEXEC_DIR" —— `--prefix "$HOME"` 会 rm -rf "$HOME/libexec"，
# `--prefix /` 会尝试 rm -rf /libexec。两者都必须被拒绝。
# KCM 目标固定指向临时文件，避免本用例把系统 KCM 当成清理对象。
SAFE_KCM="$TMPDIR_TEST/fake-kcm.so"
printf 'kcm-stub' > "$SAFE_KCM"

# 对照组：正常 prefix 行为不变
run bash "$ROOT/uninstall.sh" --prefix "$PREFIX" --skip-sudo
assert_eq "$RC" "0" "正常 prefix（mktemp 目录）行为不变"

run env BURN_WINDOW_KCM_DEST="$SAFE_KCM" bash "$ROOT/uninstall.sh" --prefix / --skip-sudo
if [ "$RC" -ne 0 ]; then pass "--prefix / 被拒绝（非零退出）"; else fail "--prefix / 被拒绝（非零退出）" "退出码 0"; fi
assert_output_contains "--prefix 不得为" "拒绝原因写 stderr（证明是被闸门拒绝，而非后续步骤失败）"

# --prefix $HOME：在 $HOME/libexec 放哨兵，跑完必须还在（无删除副作用）
GUARD_DIR="$HOME/libexec"
CREATED_GUARD=0
if [ ! -d "$GUARD_DIR" ]; then mkdir -p "$GUARD_DIR"; CREATED_GUARD=1; fi
GUARD="$GUARD_DIR/bmw-prefix-guard"
printf 'guard' > "$GUARD"

run env BURN_WINDOW_KCM_DEST="$SAFE_KCM" bash "$ROOT/uninstall.sh" --prefix "$HOME" --skip-sudo
if [ "$RC" -ne 0 ]; then pass "--prefix \$HOME 被拒绝（非零退出）"; else fail "--prefix \$HOME 被拒绝（非零退出）" "退出码 0"; fi
assert_output_contains "--prefix 不得为" "拒绝原因写 stderr"
if [ -f "$GUARD" ]; then
  pass "\$HOME/libexec 哨兵未被删除（无删除副作用）"
else
  fail "\$HOME/libexec 哨兵未被删除（无删除副作用）" "哨兵被 rm -rf 掉了"
fi
rm -f "$GUARD"
[ "$CREATED_GUARD" -eq 1 ] && rmdir "$GUARD_DIR" 2>/dev/null

# ================================================================ 9. kwinrc 失败必须保留还原能力
echo "=== test_kwinrc_failure_keeps_orig_backups ==="
# Minor-8：还原注入会 `rm -f "$orig"`（uninstall.sh:195），而 kwinrc 条目清理在它之后
# （uninstall.sh:204-225）。当 kwriteconfig6 失败时脚本 exit 1（uninstall.sh:223），
# 此时 .orig 已被删除 —— 而无配置文件时 POOL_IDS 的唯一来源正是 .orig 扫描
# （uninstall.sh:119-123），重跑即因 POOL_IDS 为空而对 19 条 *Enabled 静默不清理。
# 因此 kwinrc 清理必须先于还原，失败时备份仍在、可原地重跑。
teardown   # 前面用例已把 prefix 卸载干净，这里另起一个完整安装作为本用例现场
setup || { echo; echo "结果: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 1; }
SAFE_KCM="$TMPDIR_TEST/fake-kcm-so"
printf 'kcm-stub' > "$SAFE_KCM"
ORIG_BEFORE="$(ls "$EFFECTS"/*/contents/code/main.js.orig 2>/dev/null | wc -l | tr -d ' ')"

# 把 kwinrc 换成同名目录：kwriteconfig6 打开必然失败（实测 rc=2）
rm -f "$KWINRC"
mkdir "$KWINRC"

run env BURN_WINDOW_KCM_DEST="$SAFE_KCM" bash "$ROOT/uninstall.sh" --prefix "$PREFIX" --skip-sudo
if [ "$RC" -ne 0 ]; then
  pass "kwinrc 清理失败 → 卸载非零退出（失败不被静默吞掉）"
else
  fail "kwinrc 清理失败 → 卸载非零退出" "退出码 0"
fi

ORIG_AFTER="$(ls "$EFFECTS"/*/contents/code/main.js.orig 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "$ORIG_AFTER" "$ORIG_BEFORE" "kwinrc 失败时 .orig 备份原样保留（还原未被提前执行，可重跑）"

INJECTED_AFTER="$(grep -l 'BMW_ARBITER_BEGIN' "$EFFECTS"/*/contents/code/main.js 2>/dev/null | wc -l | tr -d ' ')"
if [ "$INJECTED_AFTER" -gt 0 ]; then
  pass "main.js 注入标记仍在（未出现'已还原但 kwinrc 残留'的半卸载）"
else
  fail "main.js 注入标记仍在" "全部已被提前还原（$INJECTED_AFTER）"
fi

# 现场清理：恢复 kwinrc 为文件、重新卸载干净，避免影响后续
rm -rf "$KWINRC"

# ---------------------------------------------------------------- 环境恢复
unset BURN_WINDOW_KCM_DEST
unset BURN_WINDOW_KCM_DEST_OLD
teardown

echo
echo "结果: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
