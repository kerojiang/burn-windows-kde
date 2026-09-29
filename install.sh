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


# ---------------------------------------------------------------- prefix 路径闸
# --prefix 是"把写入重定向到临时目录"的测试隔离参数，不是任意路径开关：
#   * 必须是绝对路径 —— 相对路径随调用方 cwd 漂移，行为不可预期；
#   * realpath 后不得为 / —— 否则 EFFECTS_DIR=/effects、LIBEXEC_DIR=/libexec；
#   * realpath 后不得为 $HOME —— uninstall.sh 的 rm -rf "$LIBEXEC_DIR" 会变成
#     rm -rf "$HOME/libexec"，删掉用户自己的目录（审查 M-3）。
# realpath -m：目标尚不存在也返回规范化结果（prefix 常是还没创建的目录）。
validate_prefix() {
  local raw="$1" real home_real
  case "$raw" in
    /*) ;;
    *)  die "--prefix 必须是绝对路径: $raw" ;;
  esac
  real="$(realpath -m -- "$raw")"
  home_real="$(realpath -m -- "$HOME")"
  [ "$real" != "/" ] || die "--prefix 不得为根目录 /（会操作 /libexec 等系统路径）"
  [ "$real" != "$home_real" ] || die "--prefix 不得为 \$HOME（会 rm -rf \$HOME/libexec 等真实目录）"
}

# ---------------------------------------------------------------- 路径解析
if [ -n "$PREFIX" ]; then
  validate_prefix "$PREFIX"
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

# ---------------------------------------------------------------- id 提取（唯一实现）
# 三处复用同一段 python：extract_pool、do_inject、emit_apply_script 生成的
# apply 脚本。此前三处各写一份且行为不一致 —— extract_pool 有 KPlugin.Id 回退
# 但 try/except 吞异常、do_inject 无回退且异常直接抛栈、apply 脚本无回退，
# 配合 `[ -n "$id" ] || continue` 把坏文件静默跳过，同一坏文件三种结局。
# 契约：成功 stdout 打印 id 并退出 0；JSON 不可解析退出 3、缺 id 字段退出 4，
#       诊断一律写 stderr —— 调用方必须 warn，绝不静默跳过。
# 代码里不得出现单引号/$/反引号/反斜杠：它会被 emit_apply_script 的未加引号
# heredoc 展开，并作为单引号字符串写进生成的 apply 脚本。
EXTRACT_ID_CODE="$(cat <<'EXTRACT_PY'
import json, sys
path = sys.argv[1]
try:
    data = json.load(open(path, encoding="utf-8"))
except Exception as exc:
    print("[extract] metadata.json 无法解析: " + path + " (" + str(exc) + ")", file=sys.stderr)
    sys.exit(3)
keyword = data.get("X-KDE-PluginKeyword") or ""
kplugin = data.get("KPlugin")
fallback = kplugin.get("Id") if isinstance(kplugin, dict) else ""
ident = keyword or fallback
if not ident:
    print("[extract] 缺少 X-KDE-PluginKeyword / KPlugin.Id: " + path, file=sys.stderr)
    sys.exit(4)
print(ident)
EXTRACT_PY
)"

extract_id() { python3 -c "$EXTRACT_ID_CODE" "$1"; }

# ---------------------------------------------------------------- 池成员提取
# 池成员始终从特效目录的 metadata.json 现场提取，不在本脚本里硬编码 19 个 ID。
# 遍历目录而非 glob metadata.json —— 否则"目录缺 metadata.json"根本进不了循环，
# 属于完全静默的漏检。
extract_pool() {
  local dir json id
  POOL_IDS=()
  for dir in "$EFFECTS_DIR"/*/; do
    [ -d "$dir" ] || continue
    json="$dir/metadata.json"
    if [ ! -f "$json" ]; then
      warn "缺少 metadata.json，跳过特效目录: $dir"
      continue
    fi
    if ! id="$(extract_id "$json")"; then
      warn "无法提取 effect id，跳过: $json"
      continue
    fi
    POOL_IDS+=("$id")
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
  local dir json id count=0
  for dir in "$EFFECTS_DIR"/*/; do
    [ -d "$dir" ] || continue
    json="$dir/metadata.json"
    if [ ! -f "$json" ]; then
      warn "缺少 metadata.json，跳过特效目录: $dir"
      continue
    fi
    if ! id="$(extract_id "$json")"; then
      warn "无法提取 effect id，跳过: $json"
      continue
    fi
    python3 "$INJECT_PY" \
      --effect-dir "$(dirname "$json")" \
      --effect-id "$id" \
      --pool "$POOL_CSV" \
      --blacklist ""
    count=$((count + 1))
  done
  [ "$count" -gt 0 ] || die "没有可注入的特效（$EFFECTS_DIR 为空）"
  # 池成员必须与注入数一致：池里有、却注入不到 → 抽签会选中未注入的特效，
  # 当次开/关窗无动画（哑弹）。提取逻辑统一后两者取自同一份 id。
  if [ "$count" -ne "${#POOL_IDS[@]}" ]; then
    die "注入数($count) 与池成员数(${#POOL_IDS[@]}) 不一致：存在无法注入的特效"
  fi
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
warn() { echo "[apply-config] 警告: \$*" >&2; }

# 与 install.sh 的 extract_pool/do_inject 同一份提取逻辑（heredoc 展开注入）
EXTRACT_ID_CODE='$EXTRACT_ID_CODE'
extract_id() { python3 -c "\$EXTRACT_ID_CODE" "\$1"; }

[ -f "\$CONFIG_FILE" ] || die "配置文件不存在: \$CONFIG_FILE"
[ -f "\$INJECT_PY" ] || die "注入器不存在: \$INJECT_PY"

POOL="\$(kreadconfig6 --file "\$CONFIG_FILE" --group General --key Pool || true)"
[ -n "\$POOL" ] || die "配置缺少 Pool 键: \$CONFIG_FILE"
BLACKLIST="\$(kreadconfig6 --file "\$CONFIG_FILE" --group General --key Blacklist || true)"

failed=0
for dir in "\$EFFECTS_DIR"/*/; do
  [ -d "\$dir" ] || continue
  json="\$dir/metadata.json"
  if [ ! -f "\$json" ]; then
    warn "缺少 metadata.json，跳过特效目录: \$dir"
    failed=1
    continue
  fi
  if ! id="\$(extract_id "\$json")"; then
    warn "无法提取 effect id，跳过: \$json"
    failed=1
    continue
  fi
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
  # 提权失败必须显式终止并说明后果：KCM 只是可选组件，前面的特效注入 / kwinrc /
  # apply 脚本已经落盘，绝不能被 set -e 静默吞掉，也不能让用户误以为整体失败。
  # 凭据通道与 uninstall.sh 保持一致：sudo 缓存优先，其次 SUDO_PASSWORD 环境变量。
  if [ -n "${SUDO_PASSWORD:-}" ]; then
    printf '%s\n' "$SUDO_PASSWORD" | sudo -S -p '' install -D -m 0644 "$KCM_SO" "$KCM_DEST" || \
      die "KCM 安装失败；已保留的用户级安装（特效注入 / kwinrc / apply 脚本）仍可用，配置未写入"
  else
    sudo install -D -m 0644 "$KCM_SO" "$KCM_DEST" || \
      die "KCM 安装失败；已保留的用户级安装（特效注入 / kwinrc / apply 脚本）仍可用，配置未写入"
  fi
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
