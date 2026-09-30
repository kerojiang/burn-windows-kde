#!/usr/bin/env bash
# 完整卸载本项目的所有安装痕迹，不留任何记录。
#
# 清理项与 install.sh 的产物一一对应：
#   1. KWin 内存中已加载的池特效（unloadEffect；非 --prefix 模式）
#   2. kwinrc 中池成员的 *Enabled 条目 + 占位特效条目 —— 必须先于还原，
#      否则 .orig 删除后池成员无从推导；占位不在池清单内须单独删除
#   3. 注入到 main.js 的仲裁代码（从 main.js.orig 还原）+ metadata 双改造
#      （从 metadata.json.orig 还原，撤销 internal/bmw-hidden）
#   4. main.js.orig / metadata.json.orig 备份本身（确认还原后删除）
#   5. kwinrc 的 *.bak.* 备份（安装时产生）
#   6. 配置文件 burn-window-randomrc
#   7. apply 脚本 burn-window-apply-config.sh
#   8. 注入器副本目录（libexec）
#   9. 系统 KCM 产物 kcm_burnwindow.so —— 新 kwin 落点与旧 systemsettings
#      落点两处都删（旧入口残留即双入口）
#  10. 特效目录本身（install.sh do_build 的 tar 解包产物）+ 占位特效目录
#      （不在池清单内）
#  11. i18n 翻译 catalog（do_install_i18n 的 kcm_burnwindow.mo，用户级共享
#      locale 目录，不随特效目录删除）
#
# 用法：
#   ./uninstall.sh                  卸载真实安装
#   ./uninstall.sh --prefix DIR     卸载 prefix 安装（测试隔离，不触碰真实 KWin）
#   ./uninstall.sh --skip-sudo      跳过需要提权的步骤
#   ./uninstall.sh --dry-run        只列出将执行的操作，不落盘
#
# 环境变量：
#   BURN_WINDOW_CONFIG / BURN_WINDOW_EFFECTS / BURN_WINDOW_KCM_DEST / BURN_WINDOW_MO  覆盖对应路径
#   SUDO_PASSWORD   提权凭据（仅经环境变量传入，不写入本脚本）
set -euo pipefail

DRY_RUN=0
SKIP_SUDO=0
PREFIX=""

# 占位特效 id 与 install.sh 同值：不在池成员清单内，其 kwinrc 条目与目录
# 都必须被显式清理（install.sh PLACEHOLDER_ID）
PLACEHOLDER_ID="kwin6_effect_bmw_random"

log()  { echo "[uninstall] $*"; }
warn() { echo "[uninstall] 警告: $*" >&2; }
die()  { echo "[uninstall] 错误: $*" >&2; exit 1; }

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# ---------------------------------------------------------------- 参数解析
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)    DRY_RUN=1 ;;
    --prefix)     PREFIX="${2:?--prefix 需要目录参数}"; shift ;;
    --skip-sudo)  SKIP_SUDO=1 ;;
    -h|--help)    usage 0 ;;
    *)            die "未知参数: $1（--help 查看用法）" ;;
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
# 与 install.sh 的路径约定逐项对齐（install.sh 路径解析段）
if [ -n "$PREFIX" ]; then
  validate_prefix "$PREFIX"
fi

if [ -n "$PREFIX" ]; then
  EFFECTS_DIR="$PREFIX/effects"
  CONFIG_FILE="$PREFIX/burn-window-randomrc"
  KWINRC="$PREFIX/kwinrc"
  APPLY_SCRIPT="$PREFIX/burn-window-apply-config.sh"
  LIBEXEC_DIR="$PREFIX/libexec"
else
  EFFECTS_DIR="${BURN_WINDOW_EFFECTS:-$HOME/.local/share/kwin/effects}"
  CONFIG_FILE="${BURN_WINDOW_CONFIG:-$HOME/.config/burn-window-randomrc}"
  KWINRC="$HOME/.config/kwinrc"
  APPLY_SCRIPT="$HOME/.local/libexec/burn-window-apply-config.sh"
  LIBEXEC_DIR="$HOME/.local/libexec/burn-window"
fi
# KCM 两落点都必须清理：新 kwin 落点（齿轮入口）与历史 systemsettings
# 落点（旧入口，残留即双入口违反 D8）；均可经环境变量覆盖供测试隔离
KCM_DEST="${BURN_WINDOW_KCM_DEST:-/usr/lib/qt6/plugins/kwin/effects/configs/kcm_burnwindow.so}"
KCM_DEST_OLD="${BURN_WINDOW_KCM_DEST_OLD:-/usr/lib/qt6/plugins/plasma/kcms/systemsettings/kcm_burnwindow.so}"
# i18n catalog（install.sh do_install_i18n 产物）：与特效目录内 zh_CN 落点
# （随特效目录整体删除覆盖）不同，该 mo 在共享 locale 目录须显式删除
MO_FILE="${BURN_WINDOW_MO:-$HOME/.local/share/locale/zh_CN/LC_MESSAGES/kcm_burnwindow.mo}"

# ---------------------------------------------------------------- 依赖检查
# 必须在任何清理动作之前完成：kwinrc 清理依赖这两个命令，若缺失则宁可
# 一个文件都不动，也不允许"已还原但 kwinrc 残留"的半卸载状态。
need() { command -v "$1" >/dev/null 2>&1 || die "缺少依赖: $1"; }
need kreadconfig6
need kwriteconfig6
if [ -z "$PREFIX" ]; then
  # unload 是尽力而为（见下方 command -v 判断），但还原仍需要注入标记可读，
  # 故仅要求基础工具；qdbus6 缺失时仅跳过 unload 并告警
  command -v qdbus6 >/dev/null 2>&1 || warn "缺少 qdbus6，将跳过 KWin unload（已加载特效仍指向旧代码）"
fi

# ---------------------------------------------------------------- 池成员收集
# 两个来源合并去重，二者任一缺失时另一个仍可独立支撑 kwinrc 清理：
#   - 配置文件的 Pool（安装完成标志，最可靠）
#   - 存在 .orig 的特效（注入过才有备份）
POOL_IDS=()

if [ -f "$CONFIG_FILE" ]; then
  csv="$(kreadconfig6 --file "$CONFIG_FILE" --group General --key Pool 2>/dev/null || true)"
  if [ -n "$csv" ]; then
    while IFS= read -r one; do
      [ -n "$one" ] && POOL_IDS+=("$one")
    done <<EOF
$(printf '%s' "$csv" | tr ',' '\n')
EOF
  fi
fi

for orig in "$EFFECTS_DIR"/*/contents/code/main.js.orig; do
  [ -e "$orig" ] || continue
  rel="${orig#"$EFFECTS_DIR"/}"
  POOL_IDS+=("${rel%%/*}")
done

# 去重排序；临时文件用 mktemp（可预测的 /tmp 路径存在符号链接抢占风险），
# 空成员行由 grep -v '^$' 过滤
if [ "${#POOL_IDS[@]}" -gt 0 ]; then
  pool_tmp="$(mktemp)"
  printf '%s\n' "${POOL_IDS[@]}" | sort -u | grep -v '^$' > "$pool_tmp" || true
  mapfile -t POOL_IDS < "$pool_tmp"
  rm -f "$pool_tmp"
fi

# ---------------------------------------------------------------- 扫描统计
RESTORE_N=0
ORIG_N=0
for orig in "$EFFECTS_DIR"/*/contents/code/main.js.orig; do
  [ -e "$orig" ] || continue
  ORIG_N=$((ORIG_N + 1))
  main="${orig%.orig}"
  if grep -q 'BMW_ARBITER_BEGIN' "$main" 2>/dev/null; then
    RESTORE_N=$((RESTORE_N + 1))
  fi
done
KWINRC_BAK_N=0
for bak in "$KWINRC".bak.*; do
  [ -e "$bak" ] || continue
  KWINRC_BAK_N=$((KWINRC_BAK_N + 1))
done

# ---------------------------------------------------------------- dry-run
if [ "$DRY_RUN" -eq 1 ]; then
  log "计划（--dry-run，不落盘）："
  if [ -z "$PREFIX" ]; then
    log "  1. unloadEffect ${#POOL_IDS[@]} 个池特效（KWin 内存）"
  else
    log "  1. 跳过 KWin unload（--prefix 隔离模式不触碰真实 KWin）"
  fi
  log "  2. 移除 kwinrc 中 ${#POOL_IDS[@]} 个池成员 Enabled 条目 + 占位条目"
  log "  3. 还原 $RESTORE_N 个 main.js（从 .orig），删除 $ORIG_N 个 .orig；还原 metadata 双改造"
  log "  4. 删除 $KWINRC_BAK_N 个 kwinrc 备份"
  log "  5. 删除配置: $CONFIG_FILE"
  log "  6. 删除 apply 脚本: $APPLY_SCRIPT"
  log "  7. 删除注入器目录: $LIBEXEC_DIR"
  log "  8. 删除 KCM 两落点: $KCM_DEST / $KCM_DEST_OLD"
  log "  9. 删除 ${#POOL_IDS[@]} 个特效目录（install.sh do_build 的 tar 解包产物）+ 占位目录"
  log "  10. 删除 i18n catalog: $MO_FILE"
  exit 0
fi

# ---------------------------------------------------------------- 1. KWin 卸载
# --prefix 是测试隔离模式，操作对象是 prefix 内的伪造环境，不得影响真实 KWin
if [ -z "$PREFIX" ] && command -v qdbus6 >/dev/null 2>&1 && [ "${#POOL_IDS[@]}" -gt 0 ]; then
  unloaded=0
  for id in "${POOL_IDS[@]}"; do
    [ -n "$id" ] || continue
    qdbus6 org.kde.KWin /Effects unloadEffect "$id" >/dev/null 2>&1 && unloaded=$((unloaded + 1)) || true
  done
  log "已从 KWin 卸载 $unloaded/${#POOL_IDS[@]} 个特效"
fi

# ---------------------------------------------------------------- 2. kwinrc 条目
# 必须先于还原注入：还原会删掉 main.js.orig（下方 3），而无配置文件时 POOL_IDS
# 的唯一来源正是 .orig 扫描（上方"池成员收集"）。若先还原、再因 kwriteconfig6
# 失败 exit 1，重跑时 POOL_IDS 为空 → 这些 *Enabled 条目被静默永久残留。
if [ "${#POOL_IDS[@]}" -gt 0 ]; then
  removed_keys=0
  failed_keys=""
  for id in "${POOL_IDS[@]}"; do
    [ -n "$id" ] || continue
    # --delete 对不存在的键是无操作（rc=0），保证幂等；真实失败必须上报 ——
    # 静默吞掉会让"已清理"的日志掩盖 kwinrc 残留
    if kwriteconfig6 --file "$KWINRC" --group Plugins --key "${id}Enabled" --delete \
         >/dev/null 2>&1; then
      removed_keys=$((removed_keys + 1))
    else
      failed_keys="$failed_keys $id"
    fi
  done
  log "已移除 kwinrc 中 $removed_keys 个池成员 Enabled 条目"
  if [ -n "$failed_keys" ]; then
    warn "kwinrc 条目删除失败（文件可能只读）:$failed_keys"
    warn "卸载不完整：请检查 $KWINRC 权限后重跑"
    exit 1
  fi
fi
# 占位条目独立删除：占位不是池成员（不参与随机），池循环覆盖不到它；
# --delete 对不存在的键幂等无操作，失败必须与池条目同等上报
if kwriteconfig6 --file "$KWINRC" --group Plugins --key "${PLACEHOLDER_ID}Enabled" --delete \
     >/dev/null 2>&1; then
  log "已移除 kwinrc 占位特效条目: ${PLACEHOLDER_ID}Enabled"
else
  warn "kwinrc 占位条目删除失败（文件可能只读）: ${PLACEHOLDER_ID}Enabled"
  warn "卸载不完整：请检查 $KWINRC 权限后重跑"
  exit 1
fi

# ---------------------------------------------------------------- 3. 还原注入
restored=0
dropped_backup=0
for orig in "$EFFECTS_DIR"/*/contents/code/main.js.orig; do
  [ -e "$orig" ] || continue
  main="${orig%.orig}"
  if grep -q 'BMW_ARBITER_BEGIN' "$main" 2>/dev/null; then
    cp "$orig" "$main"
    restored=$((restored + 1))
  else
    # main.js 已不含注入标记（此前已还原或注入中断），不得用备份覆盖
    dropped_backup=$((dropped_backup + 1))
    warn "$main 未含注入标记，仅删除备份不覆盖文件"
  fi
  rm -f "$orig"
done
log "已还原 $restored 个 main.js，删除 $ORIG_N 个 .orig"
if [ "$dropped_backup" -gt 0 ]; then
  # 这类备份对应的 main.js 已不含注入标记（此前被手工还原或注入中断），
  # 只删备份不覆盖文件；必须显式报告，否则"未还原"会被完成日志掩盖
  warn "其中 $dropped_backup 个 main.js 已不含注入标记，仅删除备份未覆盖文件"
fi

# metadata 双改造还原：.orig 是 patch 前逐字节原文，mv 覆盖即完整撤销
# （internal 移除 + 组名回正）。按 *.metadata.json.orig 全目录扫描而非池清单
# —— 还原不得依赖"该目录是否还在池里"，孤儿/边缘目录同样要还原。
# 放在特效目录删除（步骤 9）之前：目录没了就无处还原。
meta_restored=0
for orig in "$EFFECTS_DIR"/*/metadata.json.orig; do
  [ -e "$orig" ] || continue
  mv -f "$orig" "${orig%.orig}"
  meta_restored=$((meta_restored + 1))
done
log "已还原 $meta_restored 个 metadata.json（双改造撤销）"

# ---------------------------------------------------------------- 4. kwinrc 备份
if [ "$KWINRC_BAK_N" -gt 0 ]; then
  rm -f "$KWINRC".bak.*
  log "已删除 $KWINRC_BAK_N 个 kwinrc 备份"
fi

# ---------------------------------------------------------------- 5-7. 文件清理
removed_any=0
for f in "$CONFIG_FILE" "$APPLY_SCRIPT"; do
  if [ -e "$f" ]; then rm -f "$f"; removed_any=$((removed_any + 1)); fi
done
if [ -e "$LIBEXEC_DIR" ]; then
  rm -rf "$LIBEXEC_DIR"
  removed_any=$((removed_any + 1))
fi
log "已删除 $removed_any 项（配置 / apply 脚本 / 注入器目录）"

# ---------------------------------------------------------------- 8. KCM（两落点）
# 删除逻辑按提权需求分层：目标目录可写则直接删（测试用的 prefix 路径）；
# 否则需要提权，--skip-sudo 表示用户主动放弃该步骤（不算失败）。
# 新旧两落点逐个执行同一套分层；状态取最严重者（1 > 2 > 0）。
KCM_STATE=0   # 0=不存在/已删  1=需要提权但凭据不可用  2=--skip-sudo 跳过
for kcm_dest in "$KCM_DEST" "$KCM_DEST_OLD"; do
  [ -e "$kcm_dest" ] || continue
  kcm_dir="$(dirname "$kcm_dest")"
  if [ -w "$kcm_dir" ]; then
    rm -f "$kcm_dest"
    log "已删除 KCM: $kcm_dest"
  elif [ "$SKIP_SUDO" -eq 1 ]; then
    warn "已跳过 KCM 删除（--skip-sudo）: $kcm_dest"
    [ "$KCM_STATE" -eq 0 ] && KCM_STATE=2
  elif sudo -n true 2>/dev/null; then
    sudo rm -f "$kcm_dest"
    log "已删除 KCM（凭证缓存）: $kcm_dest"
  elif [ -n "${SUDO_PASSWORD:-}" ]; then
    printf '%s\n' "$SUDO_PASSWORD" | sudo -S rm -f "$kcm_dest"
    log "已删除 KCM（SUDO_PASSWORD）: $kcm_dest"
  else
    warn "KCM 需要提权但凭据不可用，未删除: $kcm_dest"
    warn "可先执行 sudo -v，或以 SUDO_PASSWORD=<密码> 方式重跑"
    KCM_STATE=1
  fi
done

# ---------------------------------------------------------------- 9. 特效目录
# 必须排在 unload(1) 与 kwinrc Enabled 移除(2) 之后：此时 KWin 已不再引用
# 这些目录，删除不会留下"注册项指向不存在目录"的悬空状态。
# 池成员目录由 install.sh do_build 段 tar 解包生成（install.sh:195
# `tar -xzf "$pkg" -C "$EFFECTS_DIR"`），属本项目安装产物，卸载必须整体
# 删除干净 —— 重装时由 do_build 重新解包恢复（卸载-重装回环依赖此语义）。
# id 校验是 rm -rf 的安全闸 —— POOL_IDS 可来自配置文件（可被外部写入），
# 含路径分隔符、点目录、或以 - 开头的成员一律拒绝
dirs_removed=0
skipped_ids=""
for id in "${POOL_IDS[@]}"; do
  [ -n "$id" ] || continue
  case "$id" in
    */*|.|..|-* ) skipped_ids="$skipped_ids $id"; continue ;;
  esac
  if [ -d "$EFFECTS_DIR/$id" ]; then
    rm -rf "$EFFECTS_DIR/$id"
    dirs_removed=$((dirs_removed + 1))
  fi
done
if [ "$dirs_removed" -gt 0 ]; then
  log "已删除 $dirs_removed 个特效目录"
fi
if [ -n "$skipped_ids" ]; then
  warn "跳过非法特效 id:$skipped_ids"
fi

# 占位特效目录：不在 POOL_IDS（不参与随机），池成员循环覆盖不到，须显式删除。
# id 是脚本内常量而非外部输入，直接删除；同样走安全闸 case 保持风格一致。
for id in "$PLACEHOLDER_ID"; do
  case "$id" in
    */*|.|..|-* ) continue ;;
  esac
  if [ -d "$EFFECTS_DIR/$id" ]; then
    rm -rf "$EFFECTS_DIR/$id"
    log "已删除占位特效目录: $id"
  fi
done

# ---------------------------------------------------------------- 10. i18n catalog
# install.sh do_install_i18n 的 KCM 翻译产物（用户级共享 locale 目录），
# 不随特效目录删除；rm -f 天然幂等，二次卸载无副作用
if [ -e "$MO_FILE" ]; then
  rm -f "$MO_FILE"
  log "已删除 i18n catalog: $MO_FILE"
fi

# ---------------------------------------------------------------- 结果
log "卸载完成（还原 $restored 个特效、清理池成员 ${#POOL_IDS[@]} 个）"

if [ "$KCM_STATE" -eq 1 ]; then
  die "卸载不完整：KCM 产物仍存在（见上方警告）"
fi
exit 0
