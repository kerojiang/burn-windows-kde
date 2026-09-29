#!/usr/bin/env bash
# Burn-My-Windows 随机特效包装层 —— 安装与配置应用入口。
#
# 用法：
#   ./install.sh                  首次安装（构建 → 注入 → 写 kwinrc → 装 KCM → 写配置）
#   ./install.sh --apply-config   黑名单变更后重新注入并重载特效（完全免 sudo、非交互）
#   ./install.sh --emit-apply-script   输出独立 apply 脚本内容（供安装时落盘）
#
# 可测试性参数（正式参数，非 test-only 后门）：
#   --prefix DIR    把所有写入路径重定向到 DIR 下平铺（effects/、burn-window-randomrc、
#                   kwinrc、burn-window-apply-config.sh），用于隔离测试
#   --dry-run       只打印计划，不落盘
#   --skip-build    跳过克隆与构建
#   --skip-kwinrc   跳过写 kwinrc
#   --skip-sudo     跳过需提权的 KCM 安装步骤
#   --fail-build    模拟构建失败（验证失败即中止、不留半安装状态）
#   --fail-sudo     模拟提权失败（验证配置不会被写入）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INJECT_PY="$ROOT/lib/inject.py"
UPSTREAM_DIR="$ROOT/upstream"
UPSTREAM_MIRROR="https://ghfast.top/https://github.com/Schneegans/Burn-My-Windows.git"
KCM_SO="$ROOT/kcm/build/bin/plasma/kcms/systemsettings/kcm_burnwindow.so"
KCM_DEST="/usr/lib/qt6/plugins/plasma/kcms/systemsettings/kcm_burnwindow.so"

DRY_RUN=0
SKIP_BUILD=0
SKIP_KWINRC=0
SKIP_SUDO=0
FAIL_BUILD=0
FAIL_SUDO=0
PREFIX=""
APPLY_CONFIG=0
EMIT_APPLY=0

POOL_IDS=()
POOL_CSV=""

log()  { echo "[install] $*"; }
warn() { echo "[install] 警告: $*" >&2; }
die()  { echo "[install] 错误: $*" >&2; exit 1; }

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# ---------------------------------------------------------------- 参数解析
while [ $# -gt 0 ]; do
  case "$1" in
    --apply-config)  APPLY_CONFIG=1 ;;
    --emit-apply-script) EMIT_APPLY=1 ;;
    --dry-run)       DRY_RUN=1 ;;
    --prefix)        PREFIX="${2:?--prefix 需要目录参数}"; shift ;;
    --skip-build)    SKIP_BUILD=1 ;;
    --skip-kwinrc)   SKIP_KWINRC=1 ;;
    --skip-sudo)     SKIP_SUDO=1 ;;
    --fail-build)    FAIL_BUILD=1 ;;
    --fail-sudo)     FAIL_SUDO=1 ;;
    -h|--help)       usage 0 ;;
    *)               die "未知参数: $1（--help 查看用法）" ;;
  esac
  shift
done

# ---------------------------------------------------------------- 路径解析
if [ -n "$PREFIX" ]; then
  EFFECTS_DIR="$PREFIX/effects"
  CONFIG_FILE="$PREFIX/burn-window-randomrc"
  KWINRC="$PREFIX/kwinrc"
  APPLY_SCRIPT="$PREFIX/burn-window-apply-config.sh"
else
  EFFECTS_DIR="$HOME/.local/share/kwin/effects"
  CONFIG_FILE="$HOME/.config/burn-window-randomrc"
  KWINRC="$HOME/.config/kwinrc"
  APPLY_SCRIPT="$HOME/.local/libexec/burn-window-apply-config.sh"
fi

# ---------------------------------------------------------------- 依赖检查
need() { command -v "$1" >/dev/null 2>&1 || die "缺少依赖: $1"; }

check_deps() {
  need python3
  need node
  need kreadconfig6
  need kwriteconfig6
  if [ "$SKIP_BUILD" -eq 0 ] || [ "$FAIL_BUILD" -eq 1 ]; then
    need cmake
    need ninja
    need git
  fi
}

# ---------------------------------------------------------------- 池成员提取
# 池成员始终从特效目录的 metadata.json 现场提取，不在本脚本里硬编码 19 个 ID。
extract_pool() {
  local json id
  POOL_IDS=()
  for json in "$EFFECTS_DIR"/*/metadata.json; do
    [ -e "$json" ] || continue
    id="$(python3 - "$json" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)
print(data.get("X-KDE-PluginKeyword") or data.get("KPlugin", {}).get("Id") or "")
PY
)"
    [ -n "$id" ] && POOL_IDS+=("$id")
  done
  POOL_CSV="$(IFS=,; echo "${POOL_IDS[*]:-}")"
  [ "${#POOL_IDS[@]}" -gt 0 ]
}

# ---------------------------------------------------------------- 构建
do_build() {
  if [ "$FAIL_BUILD" -eq 1 ]; then
    die "模拟构建失败（--fail-build）"
  fi
  [ "$SKIP_BUILD" -eq 1 ] && return 0

  if [ ! -d "$UPSTREAM_DIR/.git" ]; then
    log "克隆上游: $UPSTREAM_MIRROR"
    git clone --depth 1 "$UPSTREAM_MIRROR" "$UPSTREAM_DIR"
  fi

  log "构建 19 特效合集"
  (cd "$UPSTREAM_DIR/kwin" && ./build.sh)

  local pkg
  pkg="$(find "$UPSTREAM_DIR" -name 'burn_my_windows_kwin6.tar.gz' -print -quit)"
  [ -n "$pkg" ] || die "构建产物 burn_my_windows_kwin6.tar.gz 未找到"
  mkdir -p "$EFFECTS_DIR"
  tar -xzf "$pkg" -C "$EFFECTS_DIR"
}

# ---------------------------------------------------------------- 注入
do_inject() {
  local json id count=0
  for json in "$EFFECTS_DIR"/*/metadata.json; do
    [ -e "$json" ] || continue
    id="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("X-KDE-PluginKeyword") or "")' "$json")"
    [ -n "$id" ] || continue
    python3 "$INJECT_PY" \
      --effect-dir "$(dirname "$json")" \
      --effect-id "$id" \
      --pool "$POOL_CSV" \
      --blacklist ""
    count=$((count + 1))
  done
  [ "$count" -gt 0 ] || die "没有可注入的特效（$EFFECTS_DIR 为空）"
  log "已注入 $count 个特效"
}

# ---------------------------------------------------------------- kwinrc
do_kwinrc() {
  [ "$SKIP_KWINRC" -eq 1 ] && return 0
  if [ -f "$KWINRC" ]; then
    cp "$KWINRC" "$KWINRC.bak.$(date +%Y%m%d%H%M%S)"
    log "已备份 kwinrc"
  fi
  local id
  for id in "${POOL_IDS[@]}"; do
    kwriteconfig6 --file "$KWINRC" --group Plugins --key "${id}Enabled" true
  done
  log "已写入 ${#POOL_IDS[@]} 个 Enabled=true"
}

# ---------------------------------------------------------------- apply 脚本
# 脚本内容独立于本文件：源码目录被移动或删除后，固定路径的脚本仍可用。
# $1 = 注入器副本的绝对路径（apply 脚本运行时使用，避免依赖源码目录）
emit_apply_script() {
  local inject_path="$1"
  cat <<APPLY_EOF
#!/usr/bin/env bash
# burn-window 黑名单应用脚本
# 由 install.sh --emit-apply-script 生成，勿手动编辑。
# 契约：完全非交互、诊断走 stderr、退出码 0 表示成功。
set -euo pipefail
CONFIG_FILE="\${BURN_WINDOW_CONFIG:-\$HOME/.config/burn-window-randomrc}"
EFFECTS_DIR="\${BURN_WINDOW_EFFECTS:-\$HOME/.local/share/kwin/effects}"
INJECT_PY="\${BURN_WINDOW_INJECT:-$inject_path}"

die() { echo "[apply-config] 错误: \$*" >&2; exit 1; }

[ -f "\$CONFIG_FILE" ] || die "配置文件不存在: \$CONFIG_FILE"
[ -f "\$INJECT_PY" ] || die "注入器不存在: \$INJECT_PY"

POOL="\$(kreadconfig6 --file "\$CONFIG_FILE" --group General --key Pool || true)"
[ -n "\$POOL" ] || die "配置缺少 Pool 键: \$CONFIG_FILE"
BLACKLIST="\$(kreadconfig6 --file "\$CONFIG_FILE" --group General --key Blacklist || true)"

failed=0
for json in "\$EFFECTS_DIR"/*/metadata.json; do
  [ -e "\$json" ] || continue
  id="\$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("X-KDE-PluginKeyword") or "")' "\$json")"
  [ -n "\$id" ] || continue
  if ! python3 "\$INJECT_PY" --effect-dir "\$(dirname "\$json")" --effect-id "\$id" \\
        --pool "\$POOL" --blacklist "\$BLACKLIST"; then
    echo "[apply-config] 注入失败: \$id" >&2
    failed=1
    continue
  fi
  qdbus6 org.kde.KWin /Effects unloadEffect "\$id" >/dev/null 2>&1 || true
  qdbus6 org.kde.KWin /Effects loadEffect "\$id" >/dev/null 2>&1 \\
    || echo "[apply-config] loadEffect 失败: \$id" >&2
done

[ "\$failed" -eq 0 ] || die "部分特效注入失败"
echo "[apply-config] 完成：黑名单 [\$BLACKLIST] 已生效"
exit 0
APPLY_EOF
}

do_apply_script() {
  # 注入器必须与它的依赖 arbiter.js 成对落盘（inject.py 以自身所在目录定位
  # arbiter.js），否则源码目录移动后 apply 会因找不到 arbiter 而崩溃。
  local dst_dir
  if [ -n "$PREFIX" ]; then
    dst_dir="$PREFIX/libexec"
  else
    dst_dir="$HOME/.local/libexec/burn-window"
  fi
  mkdir -p "$dst_dir"
  cp "$ROOT/lib/inject.py" "$dst_dir/inject.py"
  cp "$ROOT/lib/arbiter.js" "$dst_dir/arbiter.js"
  chmod +x "$dst_dir/inject.py"

  emit_apply_script "$dst_dir/inject.py" > "$APPLY_SCRIPT"
  chmod +x "$APPLY_SCRIPT"
  log "已生成 apply 脚本: $APPLY_SCRIPT"
  log "已生成注入器副本: $dst_dir/{inject.py,arbiter.js}"
}

# ---------------------------------------------------------------- KCM（唯一提权步骤）
do_sudo_kcm() {
  [ "$SKIP_SUDO" -eq 1 ] && { log "已跳过 KCM 安装（--skip-sudo）"; return 0; }
  if [ "$FAIL_SUDO" -eq 1 ]; then
    die "模拟提权失败（--fail-sudo）"
  fi
  [ -f "$KCM_SO" ] || die "KCM 产物不存在，需先构建 kcm/: $KCM_SO"
  log "安装 KCM 到系统路径（需提权）"
  sudo install -D -m 0644 "$KCM_SO" "$KCM_DEST"
}

# ---------------------------------------------------------------- 配置（最后一步）
# 配置是"安装完成"的标志：必须在构建、注入、kwinrc、KCM 全部成功后才写，
# 这样任一步失败都不会留下看似已安装的状态。
do_write_config() {
  mkdir -p "$(dirname "$CONFIG_FILE")"
  cat > "$CONFIG_FILE" <<CFG_EOF
[General]
Pool=$POOL_CSV
Blacklist=
ApplyScript=$APPLY_SCRIPT
CFG_EOF
  log "已写入配置: $CONFIG_FILE"
}

# ---------------------------------------------------------------- dry-run
print_plan() {
  echo "计划（--dry-run，不落盘）："
  echo "  1. 检查依赖 (python3/node/kreadconfig6/kwriteconfig6$([ $SKIP_BUILD -eq 0 ] && echo '/cmake/ninja/git'))"
  echo "  2. $([ $SKIP_BUILD -eq 1 ] && echo '跳过构建' || echo "克隆 $UPSTREAM_MIRROR 并构建")"
  if [ "${#POOL_IDS[@]}" -gt 0 ]; then
    echo "  3. 注入 ${#POOL_IDS[@]} 个特效: ${POOL_IDS[*]}"
  else
    echo "  3. 注入特效（$EFFECTS_DIR 中暂无特效，池成员待构建后提取）"
  fi
  echo "  4. $([ $SKIP_KWINRC -eq 1 ] && echo '跳过 kwinrc' || echo "写 $KWINRC 中 ${#POOL_IDS[@]} 个 Enabled=true")"
  echo "  5. 生成 apply 脚本: $APPLY_SCRIPT"
  echo "  6. $([ $SKIP_SUDO -eq 1 ] && echo '跳过 KCM 安装' || echo "sudo 安装 KCM → $KCM_DEST")"
  echo "  7. 写配置: $CONFIG_FILE"
}

# ---------------------------------------------------------------- 配置应用
# 与 ApplyScript= 指向的独立脚本执行同一份逻辑（emit_apply_script 生成），
# 避免"子命令"与"KCM 调用的脚本"两处实现漂移。
do_apply_config() {
  # kreadconfig6 对不存在的键返回空字符串且退出码 0，无法区分"键缺失"与
  # "值为空" —— 因此文件存在性必须单独校验，不能依赖读取结果。
  [ -f "$CONFIG_FILE" ] || die "配置文件不存在: $CONFIG_FILE"

  # 注意：临时脚本路径用全局变量承载 —— 若在函数内用 local + trap EXIT，
  # 函数返回后 trap 触发时该 local 已失效，set -u 会报"未绑定的变量"。
  APPLY_TMP_SCRIPT="$(mktemp)"
  emit_apply_script "$INJECT_PY" > "$APPLY_TMP_SCRIPT"
  chmod +x "$APPLY_TMP_SCRIPT"

  local rc
  set +e
  BURN_WINDOW_CONFIG="$CONFIG_FILE" \
  BURN_WINDOW_EFFECTS="$EFFECTS_DIR" \
  BURN_WINDOW_INJECT="$INJECT_PY" \
    bash "$APPLY_TMP_SCRIPT"
  rc=$?
  set -e
  rm -f "$APPLY_TMP_SCRIPT"
  return "$rc"
}

# ---------------------------------------------------------------- 主流程
main() {
  # 子命令分发（独立 apply 逻辑见 emit_apply_script，两处必须保持等价）
  if [ "$APPLY_CONFIG" -eq 1 ]; then
    check_deps
    do_apply_config
    exit $?
  fi
  if [ "$EMIT_APPLY" -eq 1 ]; then
    emit_apply_script "$INJECT_PY"
    exit 0
  fi

  check_deps

  if [ "$DRY_RUN" -eq 1 ]; then
    if extract_pool; then
      log "池成员 (${#POOL_IDS[@]}): ${POOL_IDS[*]}"
    else
      log "池成员待构建后提取（$EFFECTS_DIR 中暂无特效）"
    fi
    print_plan
    exit 0
  fi

  # 顺序本身是需求：任一步失败即中止，配置不写（spec 7.2 #4）
  do_build
  extract_pool || die "未在 $EFFECTS_DIR 找到任何特效（池为空）"
  do_inject
  do_kwinrc
  do_apply_script
  do_sudo_kcm        # 唯一提权步骤
  do_write_config    # 最后

  log "安装完成。配置: $CONFIG_FILE"
}

main "$@"
