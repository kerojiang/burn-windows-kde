#!/usr/bin/env bash
# 端到端验收测试 —— bash tests/test_e2e.sh
#
# 前置：需先完成真实安装（brief 的 Step 3）：
#   bash install.sh --skip-build --skip-sudo && bash install.sh --apply-config
# 未安装时 test1 判 FAIL、其余用例判 SKIP（TDD 的 RED 语义，不假阴性通过）。
#
# 窗口开/关自动化（brief 实测方法）：`kwrite &` 启动触发 open（4s 含进程
# 启动延迟）→ `kill -TERM` 触发 close（3s）。播放信号按时间窗查询注入的
# `BMW_PLAY` 日志（journalctl _COMM=kwin_wayland，Ruling-15：activeEffects
# 静态含本会话播过动画的全部 effect，无法标识「正在动画」）。单轮约 7 秒。
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$HOME/.config/burn-window-randomrc"
EFFECTS="$HOME/.local/share/kwin/effects"
SAMPLE_MAIN="$EFFECTS/kwin6_effect_fire/contents/code/main.js"

PASS=0
FAIL=0
SKIP=0
OUTPUT=""
RC=0
TMP=""
INSTALLED=0

# ---------------------------------------------------------------- helpers

run() {
  set +e
  OUTPUT="$("$@" 2>&1)"
  RC=$?
  set +e
}

fail() {
  FAIL=$((FAIL + 1))
  printf '  ✖ %s\n    %s\n' "$1" "${2:-${OUTPUT:0:200}}"
}
pass() { PASS=$((PASS + 1)); printf '  ✔ %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf '  ⊘ %s —— %s\n' "$1" "$2"; }

assert_eq() { # 实际 期望 标签
  if [ "$1" = "$2" ]; then pass "$3"; else fail "$3" "期望 [$2] 实际 [$1]"; fi
}
assert_true() { # shell表达式 标签 —— 只承载 test 表达式（如 "$N -gt 0"）
  if eval "[ $1 ]"; then pass "$2"; else fail "$2" "条件不成立: $1"; fi
}
assert_cmd() { # shell命令 标签 —— 命令类断言（Ruling-14：assert_true 的 [] 包不住命令）
  if eval "$1"; then pass "$2"; else fail "$2" "命令执行失败: $1"; fi
}

PLACEHOLDER_ID="kwin6_effect_bmw_random"
KWINRC="$HOME/.config/kwinrc"

# 当前 KWin 已加载的 BMW 池成员（换行分隔、去重）。
# 排除占位 id —— 它与池成员共享 kwin6_effect_ 前缀，计入会让 LOADED_N==19
# 的断言变成 20 假失败；占位是开关载体，不属于池成员计数语义。
loaded_bmw() {
  qdbus6 org.kde.KWin /Effects org.kde.kwin.Effects.loadedEffects 2>/dev/null \
    | tr ',' '\n' | grep '^kwin6_effect_' | grep -v "^${PLACEHOLDER_ID}\$" | sort -u
}

# 全量 loadedEffects（含占位）—— 开关检测专用，与 loaded_bmw 语义区分
loaded_all() {
  qdbus6 org.kde.KWin /Effects org.kde.kwin.Effects.loadedEffects 2>/dev/null \
    | tr ',' '\n' | grep '^kwin6_effect_' | sort -u
}

# 采样时间窗内的 BMW_PLAY 播放日志（Ruling-15：activeEffects 静态含本会话
# 播过动画的全部 effect，不能标识「正在动画」；注入 winner 分支的
# console.log 经 QJSEngine ConsoleExtension 进 KWin 进程 journal，
# 按时间窗事后查询，无 50ms 轮询漏检）。
# $1=since(HH:MM:SS.mmm)  $2=until  $3=输出文件
journal_window() {
  : > "$3"
  journalctl _COMM=kwin_wayland --since "$1" --until "$2" -o cat --no-pager 2>/dev/null \
    | grep -o 'BMW_PLAY kwin6_effect_[[:alnum:]_]*' | sed 's/^BMW_PLAY //' >> "$3" || :
}

# 一轮开/关闭环：$1 = tag
# 时间锚：t0 启动 kwrite、t1 TERM（close 触发点）、t2 close 窗结束；
# open 段=[t0,t1]、close 段=[t1,t2]。动画日志在事件后毫秒级落盘，两段
# 查询都在 t2 之后执行 → 数据已写入 journal。
one_round() {
  local tag="$1" kpid t0 t1 t2
  t0="$(date +%H:%M:%S.%3N)"
  kwrite >/dev/null 2>&1 & kpid=$!
  sleep 4
  t1="$(date +%H:%M:%S.%3N)"
  kill -TERM "$kpid" 2>/dev/null
  sleep 3
  t2="$(date +%H:%M:%S.%3N)"
  kill -9 "$kpid" 2>/dev/null
  wait "$kpid" 2>/dev/null
  journal_window "$t0" "$t1" "$TMP/$tag.open.raw"
  journal_window "$t1" "$t2" "$TMP/$tag.close.raw"
  return 0
}

# 去重产出该轮的 open/close 结果文件
finalize_round() {
  local tag="$1"
  sort -u "$TMP/$tag.open.raw" 2>/dev/null | grep -v '^$' > "$TMP/$tag.open" || : > "$TMP/$tag.open"
  sort -u "$TMP/$tag.close.raw" 2>/dev/null | grep -v '^$' > "$TMP/$tag.close" || : > "$TMP/$tag.close"
}

# 连续跑 N 轮（每轮打印一个点，避免长时间无输出）
run_rounds() { # $1=前缀 $2=轮数
  local i
  for i in $(seq -w 1 "$2"); do
    one_round "$1_$i"
    finalize_round "$1_$i"
    printf '.'
  done
  printf '\n'
}

# 池成员（换行分隔）
pool_members() {
  kreadconfig6 --file "$CONFIG" --group General --key Pool 2>/dev/null \
    | tr ',' '\n' | grep -v '^$'
}

# 汇总某前缀下所有捕获（open+close 去重）
collect_all() { # $1=前缀
  cat "$TMP/$1"*.open "$TMP/$1"*.close 2>/dev/null | sort -u | grep -v '^$' || true
}

# 黑名单落盘并重新注入 + reload（apply 才会把黑名单编进 main.js）
apply_config() {
  bash "$ROOT/install.sh" --apply-config >/dev/null 2>&1
}

# 黑名单恢复（幂等）。用例 3/4 会把 Blacklist 写成 fire / 全池，若只在脚本末尾
# 恢复，中途 Ctrl-C 或异常退出就会把用户的真实配置留在全黑名单状态 —— 下次窗口
# 开合不播任何特效且无任何提示。故同时挂在 trap EXIT 上，任何退出路径都兜底还原。
BLACKLIST_RESTORED=0
restore_blacklist() {
  [ "$BLACKLIST_RESTORED" -eq 1 ] && return 0   # 正常路径与 trap EXIT 只恢复一次
  BLACKLIST_RESTORED=1
  [ "$INSTALLED" -eq 1 ] || return 0            # 未安装时不动用户配置
  kwriteconfig6 --file "$CONFIG" --group General --key Blacklist ""
  if apply_config; then
    echo "  已恢复: Blacklist 为空"
  else
    echo "  恢复失败，请手动执行: bash install.sh --apply-config"
  fi
}

# 开关链路（Task 9，Ruling-13）：写键是持久化声明（KWin 启动真相源），
# 运行时生效靠 DBus loadEffect/unloadEffect —— 实测 kwriteconfig6 --notify
# 与 /KWin reconfigure 均不触发 KWin 6.7.5 的运行时 load/unload。
# 轮询 50×0.2s=10s 超时后返回 1，由调用方决定警告还是断言失败。
random_switch() { # random_switch on|off
  if [ "$1" = on ]; then
    kwriteconfig6 --file "$KWINRC" --group Plugins --key "${PLACEHOLDER_ID}Enabled" true
    qdbus6 org.kde.KWin /Effects org.kde.kwin.Effects.loadEffect "$PLACEHOLDER_ID" >/dev/null 2>&1 || true
  else
    kwriteconfig6 --file "$KWINRC" --group Plugins --key "${PLACEHOLDER_ID}Enabled" false
    qdbus6 org.kde.KWin /Effects org.kde.kwin.Effects.unloadEffect "$PLACEHOLDER_ID" >/dev/null 2>&1 || true
  fi
  local want="$1" i loaded
  for i in $(seq 1 50); do
    loaded="$(loaded_all)"
    if { [ "$want" = on ] && printf '%s\n' "$loaded" | grep -qx "$PLACEHOLDER_ID"; } || \
       { [ "$want" = off ] && ! printf '%s\n' "$loaded" | grep -qx "$PLACEHOLDER_ID"; }; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}
# 退出兜底：测试结束把开关恢复为关（与安装后默认态一致，避免测试残留开态）
restore_random_switch() { random_switch off >/dev/null 2>&1 || true; }

# ---------------------------------------------------------------- 前置

echo "=== 前置检查 ==="
TMP="$(mktemp -d /tmp/bmw-e2e.XXXXXX)"
trap 'restore_blacklist; restore_random_switch; rm -rf "$TMP"' EXIT

LOADED_N="$(loaded_bmw | wc -l | tr -d ' ')"
if [ "$LOADED_N" -eq 0 ]; then
  echo "  未检测到已加载的 BMW 特效（loaded=0）—— 本测试只验证状态，不执行安装："
  echo "    bash install.sh --skip-build --skip-sudo && bash install.sh --apply-config"
else
  INSTALLED=1
  echo "  已加载 BMW 特效: $LOADED_N 个"
fi

# 开关前置（Task 9）：占位必须开启 —— 否则注入产物的 enabled 闸判 false，
# 19 个特效全部不播 → 用例 1-4 假失败。占位未安装时本步超时并打印警告，
# 后续开关用例按断言失败暴露（RED 语义，不假阴性通过）。
if [ "$INSTALLED" -eq 1 ]; then
  if random_switch on; then
    echo "  占位开关已开启（loadedEffects 含 $PLACEHOLDER_ID）"
  else
    echo "  警告：占位开启未生效（KWin 未运行或占位未安装），开关链路用例将失败"
  fi
fi

# ================================================================ 1. 随机分布
echo "=== test_full_install_then_random_distribution ==="
assert_eq "$LOADED_N" "19" "已加载的 BMW 特效数 == 19"

if [ "$INSTALLED" -eq 1 ]; then
  run_rounds t1 20

  ALL="$(collect_all t1)"
  N_ALL="$(printf '%s\n' "$ALL" | grep -c . || true)"
  assert_true "$N_ALL -gt 0" "20 轮中捕获到特效（共 $N_ALL 项去重）"

  # 核心合法性：每个抽中的特效都必须来自池
  POOL="$(pool_members)"
  BAD=""
  while IFS= read -r eff; do
    [ -z "$eff" ] && continue
    printf '%s\n' "$POOL" | grep -qx "$eff" || BAD="$BAD $eff"
  done <<EOF
$ALL
EOF
  if [ -z "$BAD" ]; then
    pass "抽中的特效全部 ∈ 池"
  else
    fail "抽中的特效全部 ∈ 池" "越界: $BAD"
  fi
else
  skip "20 轮开关闭环采样" "前置未安装"
  skip "抽中的特效全部 ∈ 池" "前置未安装"
fi

# ================================================================ 2. open/close 独立
echo "=== test_open_and_close_are_independent ==="
if [ "$INSTALLED" -eq 1 ]; then
  # 复用测试 1 的 20 轮采样数据，逐轮比较 open 段与 close 段的抽中项
  open_hits=0
  close_hits=0
  diff_n=0
  same_n=0
  for f in "$TMP"/t1_*.open; do
    [ -e "$f" ] || continue
    tag="$(basename "$f" .open)"
    o="$(head -1 "$f" 2>/dev/null)"
    c="$(head -1 "$TMP/$tag.close" 2>/dev/null)"
    [ -n "$o" ] && open_hits=$((open_hits + 1))
    [ -n "$c" ] && close_hits=$((close_hits + 1))
    if [ -n "$o" ] && [ -n "$c" ]; then
      if [ "$o" != "$c" ]; then diff_n=$((diff_n + 1)); else same_n=$((same_n + 1)); fi
    fi
  done

  assert_true "$open_hits -ge 5" "open 段捕获轮次 >= 5（实际 $open_hits/20）"
  assert_true "$close_hits -ge 5" "close 段捕获轮次 >= 5（实际 $close_hits/20）"
  # 若开合被绑定为同一特效，diff_n 恒为 0；19 选 1 独立随机时期望约 19/20 不同
  assert_true "$diff_n -ge 1" "存在 open ≠ close 的轮次（diff=$diff_n same=$same_n）"
else
  skip "open/close 独立性分析" "前置未安装（依赖测试 1 的采样数据）"
fi

# ================================================================ 3. 黑名单排除
echo "=== test_blacklist_excludes_effect ==="
if [ "$INSTALLED" -eq 1 ]; then
  kwriteconfig6 --file "$CONFIG" --group General --key Blacklist "kwin6_effect_fire"
  apply_config || true
  sleep 2

  run_rounds t3 20

  FIRE_HITS="$(collect_all t3 | grep '^kwin6_effect_fire$' || true)"
  if [ -z "$FIRE_HITS" ]; then
    pass "黑名单特效 kwin6_effect_fire 从未播放"
  else
    fail "黑名单特效 kwin6_effect_fire 从未播放" "出现: $FIRE_HITS"
  fi

  OTHERS="$(collect_all t3 | grep -v '^kwin6_effect_fire$' | grep -c . || true)"
  assert_true "$OTHERS -ge 1" "其余特效仍参与随机（$OTHERS 项）"
else
  skip "黑名单排除 fire" "前置未安装"
fi

# ================================================================ 4. 全黑名单
echo "=== test_all_blacklisted_plays_nothing ==="
if [ "$INSTALLED" -eq 1 ]; then
  ALL_POOL="$(pool_members | paste -sd,)"
  kwriteconfig6 --file "$CONFIG" --group General --key Blacklist "$ALL_POOL"
  apply_config || true
  sleep 2

  run_rounds t4 10

  HITS="$(collect_all t4)"
  if [ -z "$HITS" ]; then
    pass "全黑名单时无任何 kwin6_effect_* 播放"
  else
    fail "全黑名单时无任何 kwin6_effect_* 播放" "出现: $HITS"
  fi
else
  skip "全黑名单无特效" "前置未安装"
fi

# ================================================================ 5. role 不冲突
echo "=== test_role_values_do_not_collide_with_builtin ==="

# role 冲突的数据源。
#
# 首选「改 main.js + D-Bus 重载」的实时探测，但实测在当前 KWin 实例上不可行：
# 文件修改已确认生效（tail 可见 append 内容），而 5 种触发方式
# （unloadEffect+loadEffect、reconfigureEffect、/KWin reconfigure、
# unload+reconfigure+load、toggleEffect x2）读 journal 的命中数均为 0，
# 即重载不重新执行 main.js。本机 journal 中 10:35/10:58 曾有成功的重执行记录，
# 其触发方法未找到依据，无法确认（journal 不记录 shell 命令）。
# Effects.debug / supportInformation 也不输出 role 值。
#
# 故改为提取 journal 中已有的本机实测记录（该记录由 effect JS 内的探针生成，
# 含全部内置 role 取值与冲突结论），并对记录本身的完整性做断言；
# 记录不存在时标记 SKIP，不假阴性通过。
probe_role_values() {
  local rec
  rec="$(journalctl _COMM=kwin_wayland -o cat --no-pager 2>/dev/null | grep '__CONFLICTS' | tail -1)"

  if [ -z "$rec" ]; then
    skip "role 无冲突（journal 实测记录）" "journal 中无 __CONFLICTS 记录"
    return
  fi

  # 记录必须来自本项目的注入代码（自定义 role 取值正确），否则不予采信
  if printf '%s' "$rec" | grep -q '"__MINE_OPEN":424242' \
     && printf '%s' "$rec" | grep -q '"__MINE_CLOSE":424243'; then
    pass "journal 实测记录来自本项目注入（424242/424243）"
  else
    fail "journal 实测记录来自本项目注入（424242/424243）" "记录: $rec"
    return
  fi

  # 核心断言：内置 role 与自定义 role 无取值冲突
  if printf '%s' "$rec" | grep -q '"__CONFLICTS":\[\]'; then
    pass "内置 role 与自定义值无冲突（journal 实测 __CONFLICTS:[]）"
  else
    fail "内置 role 与自定义值无冲突" "journal 实测: $rec"
  fi
}

if [ "$INSTALLED" -eq 1 ]; then
  run grep -q 'const BMW_ROLE_OPEN = 424242;' "$SAMPLE_MAIN"
  if [ "$RC" -eq 0 ]; then pass "静态: 注入的 BMW_ROLE_OPEN = 424242"
  else fail "静态: 注入的 BMW_ROLE_OPEN = 424242" "main.js 中未找到该常量"; fi

  run grep -q 'const BMW_ROLE_CLOSE = 424243;' "$SAMPLE_MAIN"
  if [ "$RC" -eq 0 ]; then pass "静态: 注入的 BMW_ROLE_CLOSE = 424243"
  else fail "静态: 注入的 BMW_ROLE_CLOSE = 424243" "main.js 中未找到该常量"; fi

  probe_role_values
else
  skip "role 值静态/动态断言" "前置未安装"
fi

# ---------------------------------------------------------------- 恢复全池
# 测试 4 结束时黑名单为全量，必须恢复为空，使测试结束 = 正常安装态
echo
echo "恢复全池状态（Blacklist 置空 + 重新注入）"
restore_blacklist

# ================================================================ 开关链路三态门控
# 落点在「恢复全池」之后（Ruling-12）：用例 4 结束时 Blacklist=全池，
# 开态采样必空；恢复后 Blacklist=空才是开关用例的有效环境。
echo "=== test_random_switch_gates_playback ==="
if [ "$INSTALLED" -eq 1 ]; then
  assert_cmd "random_switch on" "开态：占位进入 loadedEffects"
  run_rounds t_on 10
  ON_N="$(collect_all t_on | grep -c . || true)"
  assert_true "$ON_N -gt 0" "开态：占位开启时产生动画（去重 $ON_N 项）"

  assert_cmd "random_switch off" "关态：占位离开 loadedEffects"
  run_rounds t_off 10
  OFF_N="$(collect_all t_off | grep -c '^kwin6_effect_' || true)"
  assert_eq "$OFF_N" "0" "关态：无任何 kwin6_effect_* 动画（enabled 闸拦截）"

  assert_cmd "random_switch on" "重开：占位回到 loadedEffects"
  run_rounds t_re 10
  RE_N="$(collect_all t_re | grep -c . || true)"
  assert_true "$RE_N -gt 0" "重开：随机播放恢复（去重 $RE_N 项）"
else
  skip "开关三态门控" "前置未安装"
fi

# ================================================================ 6. 黑名单恢复挂在退出钩子上
echo "=== test_blacklist_restored_on_any_exit ==="
# Minor-9：用例 3/4 会把 Blacklist 写成 fire / 全池，正常恢复只写在脚本末尾
# （下方"恢复全池"段）。中途 Ctrl-C、set -e 提前退出或断言路径 return 时，
# 用户的真实配置就停留在全黑名单状态 —— 下一次窗口开合不播任何特效，且无提示。
# 恢复必须经 trap EXIT 兜底，静态断言确认钩子确实注册在本脚本上。
run grep -E "^trap .*restore_blacklist.* EXIT" "$0"
if [ "$RC" -eq 0 ]; then
  pass "黑名单恢复已挂到 trap EXIT（任何退出路径都会还原）"
else
  fail "黑名单恢复已挂到 trap EXIT" "未在 $0 找到含 restore_blacklist 的 trap EXIT 行"
fi

# ================================================================ 7. 预览链路（B plan Task 4）
# 唯一能判定 caption 时序的测试（plan Review Focus #5）：开一个
# title = "BMW_PREVIEW:<id>" 的真实窗口，若 caption 晚于 windowAdded 到达，
# arbiter 走随机 → 播的不是目标 id → 断言 FAIL。
# target 与轮数可用环境变量覆盖：BMW_E2E_PREVIEW_TARGET 设为池外 id 时，
# bmwPreviewTarget 返回 null → 回落随机 → 用例必 FAIL，用于证明断言非空转
#（TDD 要求先见其失败）。默认 kwin6_effect_fire / 20 轮 —— 20 轮是必须的：
# 协议失效时单轮有 1/19 概率恰好抽中目标，单轮会假阳性通过。
echo "=== test_preview_plays_target_only ==="
PV_TARGET="${BMW_E2E_PREVIEW_TARGET:-kwin6_effect_fire}"
PV_ROUNDS="${BMW_E2E_PREVIEW_ROUNDS:-20}"

# 开窗工具链（Ruling：plan 原假设 kdialog —— 本机未安装，kwrite/konsole 也无
# --title 参数 → 改用 python3 + PyGObject GTK3）。GTK 版的 title 在
# Gtk.Window 构造时设定（先于 show），最小化 caption 晚于 windowAdded 到达的
# 可能。2026-09-30 单轮探针实测：该窗口 title 能被 KWin 读到且协议命中 ——
# 时间窗内 `BMW_PLAY` = 2 × kwin6_effect_fire（open/close 各一）。
PV_TOOL=""
if command -v kdialog >/dev/null 2>&1; then
  PV_TOOL=kdialog
elif command -v python3 >/dev/null 2>&1 \
     && python3 -c "import gi; gi.require_version('Gtk','3.0')" 2>/dev/null; then
  PV_TOOL=gtk
  cat > "$TMP/pv_win.py" <<'PYEOF'
import sys, gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, GLib
# title 在构造时给出（先于 show_all），让 Wayland set_title 先于 map
win = Gtk.Window(title=sys.argv[1])
win.set_default_size(400, 300)
win.show_all()
GLib.timeout_add(4000, Gtk.main_quit)
Gtk.main()
PYEOF
fi

preview_round() { # $1=tag $2=窗口标题（协议串）
  local tag="$1" title="$2" kpid t0 t1 t2
  t0="$(date +%H:%M:%S.%3N)"
  # 普通 toplevel 能进仲裁：main.js:253 判定 `normalWindow || window.dialog`，
  # classBlacklist（:115-121）只挡 ksmserver/ksplashqml 等，nameBlacklist
  #（:229）按 caption 精确匹配不含 BMW_PREVIEW 前缀
  if [ "$PV_TOOL" = "kdialog" ]; then
    kdialog --title "$title" --msgbox "preview" >/dev/null 2>&1 & kpid=$!
  else
    python3 "$TMP/pv_win.py" "$title" >/dev/null 2>&1 & kpid=$!
  fi
  sleep 4
  t1="$(date +%H:%M:%S.%3N)"
  kill -TERM "$kpid" 2>/dev/null
  sleep 3
  t2="$(date +%H:%M:%S.%3N)"
  kill -9 "$kpid" 2>/dev/null
  wait "$kpid" 2>/dev/null
  journal_window "$t0" "$t1" "$TMP/$tag.open.raw"
  journal_window "$t1" "$t2" "$TMP/$tag.close.raw"
  finalize_round "$tag"
  return 0
}

if [ -n "$PV_TOOL" ]; then
  printf '  预览轮次(%s via %s × %s): ' "$PV_TARGET" "$PV_TOOL" "$PV_ROUNDS"
  for i in $(seq -w 1 "$PV_ROUNDS"); do
    preview_round "t_pv_$i" "BMW_PREVIEW:$PV_TARGET"
    printf '.'
  done
  printf '\n'
  PV_ALL="$(collect_all t_pv)"
  PLAY_N="$(printf '%s\n' "$PV_ALL" | grep -c . || true)"
  TARGET_N="$(printf '%s\n' "$PV_ALL" | grep -cx "$PV_TARGET" || true)"
  assert_true "$PLAY_N -ge 1" "预览窗口触发了动画（捕获 $PLAY_N 项去重）"
  assert_eq "$TARGET_N" "$PLAY_N" "每一段播放都是目标特效（无随机泄漏）"
else
  skip "预览链路（caption 时序判定）" "kdialog 与 python3+GTK 均不可用"
fi

echo
echo "结果: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
