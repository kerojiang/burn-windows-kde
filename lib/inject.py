#!/usr/bin/env python3
"""向 KWin 特效的 main.js 注入随机仲裁代码。

用法（Task 3/4 通过此 CLI 消费）：
    python3 lib/inject.py --effect-dir <dir> --effect-id <id> \\
                          --pool <csv> --blacklist <csv> [--restore]

契约：
    成功退出码 0；锚点缺失或语法校验失败 → 退出码 2 且原因写 stderr。
    <dir>/contents/code/main.js 被就地改写，原始副本保存为同目录 main.js.orig。
    重复执行等价于"还原后再注入"，因此结果与首次注入逐字节相同。

注入点（4 个锚点，均已在 19 个上游文件上实测唯一）：
    "use strict";                 → 仲裁 helper 块
    slotWindowAdded(window) {     → 打开动画的 winner 检查
    slotWindowClosed(window) {    → 关闭动画的 winner 检查
    cleanupForcedRoles(window) {  → 动画结束时清理 winner
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

# 注入块起始标记，幂等判定依据
MARKER = "BMW_ARBITER_BEGIN"

# 仲裁 role：与 KWin 内置 role（1/2/5/6）无冲突，实测于 Plasma 6.7.5
ROLE_OPEN = 424242
ROLE_CLOSE = 424243

ARBITER_SRC = Path(__file__).resolve().parent / "arbiter.js"

# (锚点字面量, 用途标签) —— 顺序即注入顺序
ANCHORS = [
    ('"use strict";', "helper 块"),
    ("slotWindowAdded(window) {", "打开动画检查"),
    ("slotWindowClosed(window) {", "关闭动画检查"),
    ("cleanupForcedRoles(window) {", "winner 清理"),
]


def _die(message: str) -> None:
    """失败即退出：诊断走 stderr，退出码 2（CLI 契约）。"""
    print(f"[inject] 错误: {message}", file=sys.stderr)
    sys.exit(2)


def _main_path(effect_dir) -> Path:
    return Path(effect_dir) / "contents" / "code" / "main.js"


def _csv_to_json(csv: str) -> str:
    """逗号分隔列表 → 无空格 JSON 数组字面量（与 arbiter 的 string[] 接口一致）。"""
    items = [item.strip() for item in csv.split(",") if item.strip()]
    return json.dumps(items, ensure_ascii=False, separators=(",", ":"))


def _build_block(effect_id: str, pool: str, blacklist: str) -> str:
    arbiter = ARBITER_SRC.read_text(encoding="utf-8").strip()
    lines = [
        f"// === {MARKER} 由 install.sh 注入，勿手动编辑；重复注入会还原后重写 ===",
        f"const BMW_MY_EFFECT_ID = {json.dumps(effect_id, ensure_ascii=False)};",
        f"const BMW_POOL = {_csv_to_json(pool)};",
        f"const BMW_BLACKLIST = {_csv_to_json(blacklist)};",
        f"const BMW_ROLE_OPEN = {ROLE_OPEN};",
        f"const BMW_ROLE_CLOSE = {ROLE_CLOSE};",
        "",
        arbiter,
        f"// === BMW_ARBITER_END ===",
        "",
    ]
    return "\n".join(lines)


def _open_call() -> str:
    return (
        f"    // BMW_ARBITER_OPEN_BEGIN\n"
        f"    if (!bmwShouldPlay(window, BMW_ROLE_OPEN, BMW_MY_EFFECT_ID, "
        f"BMW_POOL, BMW_BLACKLIST, Math.random)) {{ return; }}\n"
        f"    // BMW_ARBITER_OPEN_END\n"
    )


def _close_call() -> str:
    return (
        f"    // BMW_ARBITER_CLOSE_BEGIN\n"
        f"    if (!bmwShouldPlay(window, BMW_ROLE_CLOSE, BMW_MY_EFFECT_ID, "
        f"BMW_POOL, BMW_BLACKLIST, Math.random)) {{ return; }}\n"
        f"    // BMW_ARBITER_CLOSE_END\n"
    )


def _cleanup_call() -> str:
    return (
        f"    // BMW_ARBITER_CLEANUP_BEGIN\n"
        f"    bmwCleanup(window, BMW_ROLE_OPEN);\n"
        f"    bmwCleanup(window, BMW_ROLE_CLOSE);\n"
        f"    // BMW_ARBITER_CLEANUP_END\n"
    )


def _insert_after(src: str, anchor: str, label: str, text: str) -> str:
    idx = src.find(anchor)
    if idx == -1:
        _die(f"锚点缺失（{label}）: {anchor!r} —— 上游 main.js 结构与预期不符")
    pos = idx + len(anchor)
    return src[:pos] + "\n" + text + src[pos:]


def _build(src: str, effect_id: str, pool: str, blacklist: str) -> str:
    # 先校验全部锚点，避免只注入一部分
    for anchor, label in ANCHORS:
        if anchor not in src:
            _die(f"锚点缺失（{label}）: {anchor!r} —— 上游 main.js 结构与预期不符")
    out = _insert_after(src, '"use strict";', "helper 块", _build_block(effect_id, pool, blacklist))
    out = _insert_after(out, "slotWindowAdded(window) {", "打开动画检查", _open_call())
    out = _insert_after(out, "slotWindowClosed(window) {", "关闭动画检查", _close_call())
    out = _insert_after(out, "cleanupForcedRoles(window) {", "winner 清理", _cleanup_call())
    return out


def _verify_syntax(src: str) -> None:
    """写入前先做 node --check，避免把语法错误的文件落到特效目录。"""
    fd, tmp = tempfile.mkstemp(suffix=".js")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(src)
        proc = subprocess.run(
            ["node", "--check", tmp], capture_output=True, text=True, check=False
        )
        if proc.returncode != 0:
            detail = (proc.stderr or proc.stdout).strip()
            _die(f"注入后语法校验失败，已放弃写入：{detail}")
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def inject(effect_dir, effect_id: str, pool: str, blacklist: str) -> None:
    """就地注入；任何失败走 _die（SystemExit 2）。"""
    main = _main_path(effect_dir)
    if not main.exists():
        _die(f"目标文件不存在: {main}")

    backup = Path(str(main) + ".orig")
    current = main.read_text(encoding="utf-8")

    if MARKER in current:
        # 已注入 → 回到首次注入前的状态，保证"重复注入"与首次逐字节相同
        if not backup.exists():
            _die(f"检测到已注入内容但缺少备份，无法安全重写: {backup}")
        original = backup.read_text(encoding="utf-8")
    else:
        original = current
        if not backup.exists():
            backup.write_text(original, encoding="utf-8")

    new_src = _build(original, effect_id, pool, blacklist)
    _verify_syntax(new_src)
    main.write_text(new_src, encoding="utf-8")


def restore(effect_dir) -> None:
    """把 main.js 还原为首次注入前的备份。"""
    main = _main_path(effect_dir)
    backup = Path(str(main) + ".orig")
    if not backup.exists():
        _die(f"备份不存在，无法还原: {backup}")
    main.write_text(backup.read_text(encoding="utf-8"), encoding="utf-8")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="向 KWin 特效 main.js 注入随机仲裁代码")
    parser.add_argument("--effect-dir", required=True, help="特效根目录（含 contents/code/main.js）")
    parser.add_argument("--effect-id", required=True, help="特效 ID，如 kwin6_effect_fire")
    parser.add_argument("--pool", default="", help="参与随机的特效 ID，逗号分隔")
    parser.add_argument("--blacklist", default="", help="被剔除的特效 ID，逗号分隔")
    parser.add_argument("--restore", action="store_true", help="还原为备份而非注入")
    args = parser.parse_args(argv)

    if args.restore:
        restore(args.effect_dir)
    else:
        inject(args.effect_dir, args.effect_id, args.pool, args.blacklist)
    return 0


if __name__ == "__main__":
    sys.exit(main())
