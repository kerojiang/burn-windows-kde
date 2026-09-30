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
  local d id src
  for d in "$REAL_EFFECTS"/*/; do
    id="$(basename "$d")"
    mkdir -p "$PREFIX/effects/$id/contents/code"
    # metadata 同样必须是上游纯净态：真实环境被 patch 后 metadata.json 是
    # 改造态而 .orig 才是原文，只复制 .orig 才能让幂等/备份断言与环境状态解耦
    src="$d/metadata.json.orig"
    [ -e "$src" ] || src="$d/metadata.json"
    cp "$src" "$PREFIX/effects/$id/metadata.json" 2>/dev/null || true
    # fixture 必须是上游纯净态：真实环境被 e2e 首装后 main.js 已注入，
    # 而 inject.py 对"已注入但缺 .orig"会 exit 2（lib/inject.py 152-155）
    src="$d/contents/code/main.js.orig"
    [ -e "$src" ] || src="$d/contents/code/main.js"
    cp "$src" "$PREFIX/effects/$id/contents/code/main.js" 2>/dev/null || true
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

# 与 test_e2e.sh 同款：条件守卫（如 kcm/build 已有产物时避免覆盖）走此分支。
# 缺失定义会让守卫段 command not found 且断言静默不执行（62→58 条之谜，Ruling-16）。
skip() {
  SKIP=$((SKIP + 1))
  printf '  ⊘ %s —— %s\n' "$1" "$2"
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

# ---------------------------------------------------------------- 占位模板（静态，不依赖安装）
echo "=== test_placeholder_template ==="
TEMPLATE="$ROOT/placeholder/kwin6_effect_bmw_random"
assert_exists "$TEMPLATE/metadata.json" "占位 metadata.json 存在"
assert_exists "$TEMPLATE/contents/code/main.js" "占位 main.js 存在"
if [ -f "$TEMPLATE/metadata.json" ]; then
  if python3 - "$TEMPLATE/metadata.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
assert m["KPackageStructure"] == "KWin/Effect"
assert m["KPlugin"]["Id"] == "kwin6_effect_bmw_random"
# i18n（2026-09-30）：Name/Description 原文英文（KDE 规范），中文走语言键；
# zh_CN 主键（KWin 官方惯例，KPluginMetaData 按 zh_CN 查）+ zh_Hans 兼容键
assert m["KPlugin"]["Name"] == "Random Effects [Burn-My-Windows]"
assert m["KPlugin"]["Name[zh_CN]"] == "随机特效 [Burn-My-Windows]"
assert m["KPlugin"]["Name[zh_Hans]"] == "随机特效 [Burn-My-Windows]"
assert m["KPlugin"]["Description"] == "Randomly plays Burn-My-Windows window open/close animations"
assert m["KPlugin"]["Description[zh_CN]"] == "随机播放 Burn-My-Windows 的窗口开/关动画"
assert m["KPlugin"]["Description[zh_Hans]"] == "随机播放 Burn-My-Windows 的窗口开/关动画"
assert m["KPlugin"]["EnabledByDefault"] is False
assert m["X-KWin-Exclusive-Category"] == "toplevel-open-close-animation"
assert m["X-KDE-ConfigModule"] == "kcm_burnwindow"
assert m["X-Plasma-API"] == "javascript"
assert m["X-Plasma-MainScript"] == "code/main.js"
PY
  then pass "占位字段断言"
  else fail "占位字段断言" "字段不符（见上方 Python 断言输出）"
  fi
fi
run node --check "$TEMPLATE/contents/code/main.js"
assert_exit_code_zero "占位 main.js 语法通过 node --check"

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

echo "=== test_broken_metadata_is_reported_not_skipped ==="
# 审查 M-5：id 提取在 extract_pool(原 105)/do_inject(原 141)/apply 脚本(原 195)
# 三处各写一份、行为不一致，且 extract_pool 的 try/except 吞异常、
# `[ -n "$id" ] || continue` 静默跳过 —— 同一坏文件三种结局，池成员可能取到 id
# 而注入取不到 → 抽签选中未注入特效 → 当次无动画（哑弹）。
# 三种坏数据都必须被显式报告（诊断含 [install] 警告），不得静默跳过。

# 场景 1：特效目录缺 metadata.json
setup
BROKEN="$PREFIX/effects/kwin6_effect_broken"
mkdir -p "$BROKEN/contents/code"
printf 'console.log("x");\n' > "$BROKEN/contents/code/main.js"
run bash "$INSTALL" --prefix "$PREFIX" --skip-sudo --skip-build --skip-kwinrc
assert_output_contains "[install] 警告" "缺 metadata.json 被报告，而非静默跳过"

# 场景 2：metadata.json 缺 id 字段
setup
printf '{"KPlugin":{"Name":"NoIdHere"}}' > "$PREFIX/effects/kwin6_effect_fire/metadata.json"
run bash "$INSTALL" --prefix "$PREFIX" --skip-sudo --skip-build --skip-kwinrc
assert_output_contains "[install] 警告" "缺 id 字段被报告，而非静默跳过"

# 场景 3：metadata.json 损坏（JSON 不可解析）
setup
printf '{broken json' > "$PREFIX/effects/kwin6_effect_fire/metadata.json"
run bash "$INSTALL" --prefix "$PREFIX" --skip-sudo --skip-build --skip-kwinrc
assert_output_contains "[install] 警告" "损坏的 JSON 被报告，而非被 try/except 吞掉"
teardown

echo "=== test_third_party_effect_does_not_abort_install ==="
# P1-1：用户 effects 目录存在第三方特效（合法 metadata 可提取 id、main.js
# 无 BMW 注入锚点）时，安装不得中止（inject.py 锚点缺失 _die + set -e 会
# 直接退出），第三方不入池、不注入、不被 metadata 双改造。
setup
THIRD="$PREFIX/effects/kwin6_effect_thirdparty"
mkdir -p "$THIRD/contents/code"
printf '{"KPlugin":{"Id":"kwin6_effect_thirdparty","Name":"Third Party"}}' > "$THIRD/metadata.json"
printf '// 第三方特效：无 slotWindowAdded 等 BMW 锚点\nfunction animate() {}\n' > "$THIRD/contents/code/main.js"
run bash "$INSTALL" --prefix "$PREFIX" --skip-sudo --skip-build --skip-kwinrc
assert_eq "$RC" "0" "第三方特效不中止安装（退出码 0）"
if grep -q 'BMW_ARBITER_BEGIN' "$THIRD/contents/code/main.js" 2>/dev/null; then
  fail "第三方特效未被注入" "main.js 出现仲裁锚点标记"
else
  pass "第三方特效未被注入"
fi
POOL_NOW="$(kreadconfig6 --file "$PREFIX/burn-window-randomrc" --group General --key Pool 2>/dev/null || true)"
case "$POOL_NOW" in
  *kwin6_effect_thirdparty*) fail "第三方不入池" "Pool 含 thirdparty: $POOL_NOW" ;;
  *) pass "第三方不入池" ;;
esac
if grep -q 'X-KWin-Internal' "$THIRD/metadata.json" 2>/dev/null; then
  fail "第三方 metadata 未被双改造" "被写入 X-KWin-Internal"
else
  pass "第三方 metadata 未被双改造"
fi
# 池成员数 = fixture 池成员数（setup 复制真实 effects：19 BMW + 占位，占位不入池）
N_POOL="$(printf '%s' "$POOL_NOW" | tr ',' '\n' | grep -c . || true)"
REAL_N=0
for d in "$REAL_EFFECTS"/*/; do
  b="$(basename "$d")"
  [ "$b" = "kwin6_effect_bmw_random" ] && continue
  [ -d "$d" ] && REAL_N=$((REAL_N + 1))
done
assert_eq "$N_POOL" "$REAL_N" "池成员数与真实 BMW 特效数一致（第三方被排除）"
teardown

echo "=== test_apply_config_skips_build_deps ==="
# P1-6：--apply-config 是 KCM Apply 的非交互入口（免 sudo、不构建），不得走
# 构建依赖闸 —— check_deps 在 SKIP_BUILD=0 时 need cmake/ninja/git，无构建
# 工具的机器上黑名单变更直接 die。受限 PATH 行为断言被 realpath 等基础命令
# 的清单脆性破坏（实测 mock 缺 realpath 在行 84 早退、断言语义失真），
# 改为静态断言：分支体不调 check_deps、内联精简依赖。
APPLY_BRANCH="$(awk '/^  if \[ "\$APPLY_CONFIG" -eq 1 \]/{f=1} f{print} f && /^  fi$/{exit}' "$INSTALL")"
# 只断言代码行：注释提及 check_deps（解释设计取舍）不算调用
APPLY_BRANCH_CODE="$(printf '%s\n' "$APPLY_BRANCH" | grep -v '^[[:space:]]*#' || true)"
case "$APPLY_BRANCH_CODE" in
  *check_deps*) fail "apply-config 分支不调用 check_deps" "分支代码仍调用 check_deps" ;;
  *) pass "apply-config 分支不调用 check_deps" ;;
esac
case "$APPLY_BRANCH" in
  *need\ python3*) pass "apply-config 分支内联精简依赖（need python3）" ;;
  *) fail "apply-config 分支内联精简依赖（need python3）" "分支体未找到 need python3" ;;
esac

echo "=== test_kwinrc_write_uses_notify_with_relative_path ==="
# P1-2 + Ruling-13：写 Enabled 键必须带 --notify 且用相对名 kwinrc —— 绝对
# 路径时 notify path=/home/.../kwinrc ≠ KWin 订阅的 /kwinrc，通知链不触发；
# 完成提示须告知新装特效的生效方式（KWin 发现目录后通知链才可控）。
# 实现为条件变量（prefix 隔离保持绝对路径、真实环境赋相对名 kwinrc），
# 组合断言：写键行带 --notify --file "$kwinrc_arg" + 真实环境分支赋值 kwinrc
if grep -q 'kwriteconfig6 --notify --file "$kwinrc_arg" --group Plugins' "$INSTALL" \
   && grep -q 'kwinrc_arg="kwinrc"' "$INSTALL"; then
  pass "写键带 --notify 且真实环境用相对名 kwinrc"
else
  fail "写键带 --notify 且真实环境用相对名 kwinrc" "未找到 --notify 写键行或 kwinrc 相对名赋值"
fi
if grep -q '重启 KWin' "$INSTALL"; then
  pass "安装完成提示含「重启 KWin」生效说明"
else
  fail "安装完成提示含「重启 KWin」生效说明" "完成提示未告知生效方式"
fi

echo "=== test_real_sudo_failure_keeps_user_install_hint ==="
# Minor-1：真实 `sudo install` 失败走 set -e 直接退出、不经 die，因此没有
# Task3 Step3 要求的"已保留的用户级安装"提示（只有 --fail-sudo 分支才有）。
# setsid 让脚本脱离控制终端 → Arch 的 sudo 必然要求密码而失败，复现真实提权失败。
KCM_SO="$ROOT/kcm/build/bin/plasma/kcms/systemsettings/kcm_burnwindow.so"
# 系统生产落点（install.sh:27 KCM_DEST）—— 假 .so 绝不能落到这里
REAL_KCM_DEST="/usr/lib/qt6/plugins/kwin/effects/configs/kcm_burnwindow.so"
if [ -e "$KCM_SO" ]; then
  skip "提权失败时的用户级安装提示" "kcm/build 已有产物，避免覆盖"
else
  setup
  mkdir -p "$(dirname "$KCM_SO")"
  printf 'fake-so-for-sudo-fail-test' > "$KCM_SO"
  # 注入式假 sudo（P1-4 终版）：真实 setsid+sudo 失败会给 pam_faillock 计
  # 一次失败 —— 2026-09-29 实测累计达阈值后账户临时锁定，殃及后续 kcm
  # 套件连正确密码都被拒（journal: pam_faillock temporarily locked）；
  # 且 SUDO_PASSWORD 在场时真实提权会把 30B 假 .so 写进系统生产路径。
  # 假 sudo 对 -n 探测与实际提权一律失败：不碰 PAM、不依赖 tty/缓存，
  # 确定性覆盖 install.sh 的提权失败错误处理路径。
  FAKE_BIN="$(mktemp -d /tmp/bmw-fakesudo.XXXXXX)"
  printf '#!/bin/sh\nif [ "$1" = "-n" ]; then exit 1; fi\necho "sudo: 模拟提权失败（测试注入）" >&2\nexit 1\n' > "$FAKE_BIN/sudo"
  chmod +x "$FAKE_BIN/sudo"
  run env PATH="$FAKE_BIN:$PATH" bash "$INSTALL" --prefix "$PREFIX" --skip-build --skip-kwinrc < /dev/null
  assert_exit_code_nonzero "提权失败（假 sudo）→ 退出码非 0"
  assert_output_contains "KCM 安装失败" "失败原因被显式打印（不是被 set -e 静默退出）"
  assert_output_contains "已保留的用户级安装" "提示已保留的用户级安装仍可用"
  assert_not_exists "$PREFIX/burn-window-randomrc" "配置未写入（半安装不留标志）"
  if grep -q 'fake-so-for-sudo-fail-test' "$REAL_KCM_DEST" 2>/dev/null; then
    fail "系统 KCM 生产落点未被测试桩污染" "$REAL_KCM_DEST 含 fake-so 内容"
  else
    pass "系统 KCM 生产落点未被测试桩污染"
  fi
  rm -rf "$FAKE_BIN"
  rm -f "$KCM_SO"
  rmdir -p "$(dirname "$KCM_SO")" 2>/dev/null || true
  teardown
fi

echo "=== test_prefix_rejects_root_and_home ==="
# 路径闸（审查 M-3）：--prefix / 会写 /libexec 等系统路径，--prefix $HOME
# 会 rm -rf $HOME/libexec —— 两者都必须被拒绝，且不得留下任何写入/删除副作用。
setup
run bash "$INSTALL" --prefix "$PREFIX" --skip-sudo --skip-build --skip-kwinrc
assert_exit_code_zero "正常 prefix（mktemp 目录）行为不变"

run bash "$INSTALL" --prefix / --skip-build --skip-sudo
assert_exit_code_nonzero "--prefix / 被拒绝（非零退出）"
assert_output_contains "--prefix 不得为" "拒绝原因写 stderr（证明是被闸门拒绝，而非后续步骤失败）"
assert_not_exists "/burn-window-randomrc" "未在 / 写入配置"
assert_not_exists "/effects" "未在 / 创建特效目录"

run bash "$INSTALL" --prefix "$HOME" --skip-sudo --skip-build
assert_exit_code_nonzero "--prefix \$HOME 被拒绝（非零退出）"
assert_output_contains "--prefix 不得为" "拒绝原因写 stderr"
assert_not_exists "$HOME/burn-window-randomrc" "未在 \$HOME 顶层写配置"
assert_not_exists "$HOME/burn-window-apply-config.sh" "未在 \$HOME 顶层写 apply 脚本"
assert_not_exists "$HOME/kwinrc" "未在 \$HOME 顶层写 kwinrc"
teardown

# ---------------------------------------------------------------- Task 4: 占位 + metadata patch + KCM 落点
echo "=== test_placeholder_installed ==="
setup
run bash "$INSTALL" --prefix "$PREFIX" --skip-sudo --skip-build
assert_exit_code_zero "首装退出码为 0"
PH="$PREFIX/effects/kwin6_effect_bmw_random"
assert_exists "$PH/metadata.json" "占位 metadata.json 已装入 effects 目录"
if [ -f "$PH/metadata.json" ]; then
  if python3 - "$PH/metadata.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
assert m["KPlugin"]["Id"] == "kwin6_effect_bmw_random"
# i18n（2026-09-30）：部署产物与模板同样要求双语键（cp 部署必须带键）；
# zh_CN 主键（KWin 官方惯例）+ zh_Hans 兼容键
assert m["KPlugin"]["Name"] == "Random Effects [Burn-My-Windows]"
assert m["KPlugin"]["Name[zh_CN]"] == "随机特效 [Burn-My-Windows]"
assert m["KPlugin"]["Name[zh_Hans]"] == "随机特效 [Burn-My-Windows]"
assert m["KPlugin"]["Description"] == "Randomly plays Burn-My-Windows window open/close animations"
assert m["KPlugin"]["Description[zh_CN]"] == "随机播放 Burn-My-Windows 的窗口开/关动画"
assert m["KPlugin"]["Description[zh_Hans]"] == "随机播放 Burn-My-Windows 的窗口开/关动画"
assert m["KPlugin"]["EnabledByDefault"] is False
assert m["X-KDE-ConfigModule"] == "kcm_burnwindow"
PY
  then pass "占位字段与模板一致"
  else fail "占位字段与模板一致" "字段不符（见上方 Python 断言输出）"
  fi
fi
assert_exists "$PH/contents/code/main.js" "占位 main.js 存在"
if [ -f "$PH/contents/code/main.js" ]; then
  # Review Focus #1：占位混入注入遍历会因缺锚点 _die 中止安装/apply
  if grep -q "BMW_ARBITER" "$PH/contents/code/main.js"; then
    fail "占位 main.js 未被注入" "含 BMW_ARBITER 标记（占位混入注入遍历）"
  else
    pass "占位 main.js 未被注入"
  fi
fi
teardown

echo "=== test_metadata_patched_19 ==="
setup
run bash "$INSTALL" --prefix "$PREFIX" --skip-sudo --skip-build
assert_exit_code_zero "首装退出码为 0"
if python3 - "$PREFIX/effects" <<'PY'
import json, sys
from pathlib import Path
effects = Path(sys.argv[1])
patched = 0
for d in sorted(p for p in effects.iterdir() if p.is_dir()):
    if d.name == "kwin6_effect_bmw_random":
        continue  # 占位必须保持可见，不参与双改造
    m = json.loads((d / "metadata.json").read_text(encoding="utf-8"))
    assert m.get("X-KWin-Internal") == "true", f"{d.name} 缺 X-KWin-Internal"
    assert m.get("X-KWin-Exclusive-Category") == "bmw-hidden", f"{d.name} 组名未改"
    assert (d / "metadata.json.orig").exists(), f"{d.name} 缺 .orig 备份"
    assert m["KPlugin"]["Id"] == d.name, f"{d.name} KPlugin.Id 被改动"
    patched += 1
assert patched == 19, f"patched={patched}，期望 19"
PY
then pass "19 个 metadata 双改造 + .orig 备份，占位不 patch"
else fail "19 个 metadata 双改造 + .orig 备份，占位不 patch" "见上方断言输出"
fi
teardown

echo "=== test_install_idempotent ==="
setup
run bash "$INSTALL" --prefix "$PREFIX" --skip-sudo --skip-build
assert_exit_code_zero "第一次安装退出码为 0"
ORIG1="$(md5sum "$PREFIX/effects/kwin6_effect_fire/metadata.json.orig" 2>/dev/null | cut -d' ' -f1)"
run bash "$INSTALL" --prefix "$PREFIX" --skip-sudo --skip-build
assert_exit_code_zero "第二次安装退出码为 0"
ORIG2="$(md5sum "$PREFIX/effects/kwin6_effect_fire/metadata.json.orig" 2>/dev/null | cut -d' ' -f1)"
assert_eq "$ORIG2" "$ORIG1" ".orig 保留首改原文（二次安装不覆盖备份）"
assert_eq "$(grep -c 'BMW_ARBITER_BEGIN' "$PREFIX/effects/kwin6_effect_fire/contents/code/main.js")" "1" "main.js 注入仍只有一份"
teardown

echo "=== test_apply_skips_placeholder ==="
# Review Focus #1 的裁判：占位混入 apply 遍历 → 空 main.js 无锚点 → inject _die → 非零退出
setup
run bash "$INSTALL" --prefix "$PREFIX" --skip-sudo --skip-build
assert_exit_code_zero "首装退出码为 0"
run bash "$INSTALL" --prefix "$PREFIX" --apply-config
assert_exit_code_zero "apply-config 退出码为 0（占位已被跳过）"
assert_output_contains "完成" "apply 输出完成文案"
teardown

echo "=== test_kcm_dest_new_path ==="
setup
# D8 单一入口：KCM 必须落 kwin/effects/configs（齿轮经 ConfigModule 按 id 查找），
# 旧 systemsettings 落点一旦残留就会与聚合页形成双入口
if grep -q '^KCM_DEST="/usr/lib/qt6/plugins/kwin/effects/configs/kcm_burnwindow.so"$' "$INSTALL"; then
  pass "KCM_DEST 赋值指向 kwin/effects/configs 新落点"
else
  fail "KCM_DEST 赋值指向 kwin/effects/configs 新落点" "未找到新落点赋值"
fi
if grep -q '^KCM_DEST=.*plasma/kcms/systemsettings' "$INSTALL"; then
  fail "KCM_DEST 旧落点赋值已移除" "仍存在旧 systemsettings 赋值"
else
  pass "KCM_DEST 旧落点赋值已移除"
fi
run bash "$INSTALL" --dry-run --prefix "$PREFIX"
assert_output_contains "kwin/effects/configs" "--dry-run 计划打印新 KCM 落点"
teardown

echo "=== test_old_kcm_dest_cleanup ==="
FUNC_BODY="$(sed -n '/^do_sudo_kcm() {/,/^}/p' "$INSTALL")"
if printf '%s' "$FUNC_BODY" | grep -q 'KCM_DEST_OLD'; then
  pass "do_sudo_kcm 含旧落点清理逻辑"
else
  fail "do_sudo_kcm 含旧落点清理逻辑" "函数体未引用 KCM_DEST_OLD"
fi
if grep -q '^KCM_DEST_OLD="/usr/lib/qt6/plugins/plasma/kcms/systemsettings/kcm_burnwindow.so"$' "$INSTALL"; then
  pass "KCM_DEST_OLD 定义为旧 systemsettings 落点"
else
  fail "KCM_DEST_OLD 定义为旧 systemsettings 落点" "未找到字面定义"
fi

echo "=== test_do_build_builds_kcm ==="
# 根因（2026-09-30 实测，用户手动验收反馈「每个特效右边没有任何显示」）：
# 新落点 .so 是 Task 4/5 版陈旧产物 —— nm -C 实测缺 toggleParticipating/
# setParam/randomLoaded，QML 调用集只有 kcm.toggleBlacklist（勾=剔除的
# 黑名单页），故 QML 的 visible: params.length > 0 恒假、参数入口不渲染。
# 直接原因：install.sh 只在 :24 从 kcm/build/bin/ 取 KCM_SO，而 do_build()
# 全函数仅 git clone + upstream/kwin/build.sh + tar 解包（grep 实证全脚本
# 除 :24 外零处构建 KCM）→ 产物永不重建、不校验新鲜度，陈旧 .so 被原样装入。
# 断言为静态（去注释后匹配命令词）：行为方案需真跑 upstream 全量构建
# （19 特效 build.sh，分钟级）且 kcm/build 是仓库内固定路径、无 prefix 隔离，
# 与 P1-6 同款取舍（该段注释记录了同类脆性废弃）。
BUILD_BODY="$(sed -n '/^do_build() {/,/^}/p' "$INSTALL")"
if [ -z "$BUILD_BODY" ]; then
  fail "do_build 含 KCM 构建" "未提取到 do_build 函数体"
else
  # 仅代码行参与断言：注释里的设计说明不算调用
  BUILD_CODE="$(printf '%s\n' "$BUILD_BODY" | grep -v '^[[:space:]]*#' || true)"
  if printf '%s\n' "$BUILD_CODE" | grep -q 'kcm' \
     && printf '%s\n' "$BUILD_CODE" | grep -qE 'cmake|ninja'; then
    pass "do_build 构建 KCM"
  else
    fail "do_build 构建 KCM" "do_build 代码行未同时出现 kcm 与 cmake/ninja 构建命令"
  fi

  # KCM 构建必须位于 SKIP_BUILD early-return 之后 —— 否则 --skip-build 仍会
  # 拖入 cmake 依赖，破坏该旗标语义（跳过克隆与构建、无构建工具机器可装）。
  AFTER_SKIP="$(printf '%s\n' "$BUILD_BODY" | awk '/SKIP_BUILD.*return 0/{f=1;next} f{print}')"
  AFTER_SKIP_CODE="$(printf '%s\n' "$AFTER_SKIP" | grep -v '^[[:space:]]*#' || true)"
  if printf '%s\n' "$AFTER_SKIP_CODE" | grep -qE 'cmake|ninja'; then
    pass "KCM 构建受 --skip-build 管辖"
  else
    fail "KCM 构建受 --skip-build 管辖" "KCM 构建不在 SKIP_BUILD early-return 之后（或未受其管辖）"
  fi
fi

echo "=== test_kcm_installed_mode_matches_peers ==="
# 可选项 A（用户批准一并修）：install -D -m 0644 使 .so 落成 rw-r--r--，
# 而新落点同目录 16 个上游 .so 实测全为 rwxr-xr-x（755）。dlopen 不需 x 位、
# 当前也能加载，但与系统插件惯例不一致 → 与同目录惯例对齐。
SUDO_FUNC_CODE="$(sed -n '/^do_sudo_kcm() {/,/^}/p' "$INSTALL" | grep -v '^[[:space:]]*#' || true)"
case "$SUDO_FUNC_CODE" in
  *'install -D -m 0755'*) pass "KCM 安装 mode 为 0755（与同目录插件惯例一致）" ;;
  *) fail "KCM 安装 mode 为 0755（与同目录插件惯例一致）" "do_sudo_kcm 未用 install -D -m 0755 安装 KCM_SO" ;;
esac

echo
echo "结果: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
