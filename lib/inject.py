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

# 占位特效 id：注入产物以此查询总开关加载态（effects.isEffectLoaded）
PLACEHOLDER_ID = "kwin6_effect_bmw_random"

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
        f'const BMW_PLACEHOLDER_ID = {json.dumps(PLACEHOLDER_ID)};',
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
        f"BMW_POOL, BMW_BLACKLIST, Math.random, "
        f"effects.isEffectLoaded(BMW_PLACEHOLDER_ID))) {{ return; }}\n"
        f"    console.log(\"BMW_PLAY \" + BMW_MY_EFFECT_ID);\n"
        f"    // BMW_ARBITER_OPEN_END\n"
    )


def _close_call() -> str:
    return (
        f"    // BMW_ARBITER_CLOSE_BEGIN\n"
        f"    if (!bmwShouldPlay(window, BMW_ROLE_CLOSE, BMW_MY_EFFECT_ID, "
        f"BMW_POOL, BMW_BLACKLIST, Math.random, "
        f"effects.isEffectLoaded(BMW_PLACEHOLDER_ID))) {{ return; }}\n"
        f"    console.log(\"BMW_PLAY \" + BMW_MY_EFFECT_ID);\n"
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


def _meta_path(effect_dir) -> Path:
    return Path(effect_dir) / "metadata.json"


# i18n（2026-09-30）：19 特效 metadata 语言键素材。Name 中译与上游
# po/zh_Hans.po 的特效名条目一致（Fire→烈火燃烧 等）；Description 为本项目
# 翻译（上游 pot 无 Description msgid）。key = 部署目录名（KWin 效果 id）。
BMW_ZH_META = {
    "kwin6_effect_aura_glow": ("辉光萦绕 [Burn-My-Windows]", "边缘点亮的辉光动画"),
    "kwin6_effect_doom": ("毁灭战士 [Burn-My-Windows]", "让你的窗口融化"),
    "kwin6_effect_energize_a": ("碎片融解A [Burn-My-Windows]", "用光束把窗口传送走"),
    "kwin6_effect_energize_b": ("碎片融解B [Burn-My-Windows]", "换用另一种传送技术，呈现不同的视觉效果"),
    "kwin6_effect_fire": ("烈火燃烧 [Burn-My-Windows]", "致敬 Compiz 的经典特效"),
    "kwin6_effect_focus": ("聚焦 [Burn-My-Windows]", "专注点，老兄！"),
    "kwin6_effect_glide": ("滑翔 [Burn-My-Windows]", "以细腻的 3D 效果将窗口淡出至透明"),
    "kwin6_effect_glitch": ("电子脉冲 [Burn-My-Windows]", "给你的窗口加上一些有意为之的图形故障"),
    "kwin6_effect_hexagon": ("蜂巢拼图 [Burn-My-Windows]", "发光线条与六边形瓷砖，科技感十足"),
    "kwin6_effect_incinerate": ("燃烧蔓开 [Burn-My-Windows]", "比火焰更慢、但绝对更华丽的演绎"),
    "kwin6_effect_pixelate": ("像素化 [Burn-My-Windows]", "窗口像素化并随机隐藏像素"),
    "kwin6_effect_pixel_wheel": ("像素轮 [Burn-My-Windows]", "窗口像素化并以轮盘样式隐藏像素"),
    "kwin6_effect_pixel_wipe": ("像素擦除 [Burn-My-Windows]", "窗口像素化并从指针位置开始径向隐藏像素"),
    "kwin6_effect_portal": ("传送门 [Burn-My-Windows]", "把窗口传送到其他时空"),
    "kwin6_effect_rgbwarp": ("炫彩跃迁 [Burn-My-Windows]", "红蓝绿，再见啦"),
    "kwin6_effect_team_rocket": ("火箭疾袭 [Burn-My-Windows]", "……又飞向宇宙了！"),
    "kwin6_effect_tv": ("电视效果 [Burn-My-Windows]", "关窗时像关掉一台电视"),
    "kwin6_effect_tv_glitch": ("电视故障 [Burn-My-Windows]", "关窗时像一台故障频发的老式电视"),
    "kwin6_effect_wisps": ("精灵飞散 [Burn-My-Windows]", "让这些小精灵把你的窗口带入梦乡"),
}


def patch_metadata(effect_dir) -> bool:
    """metadata 三改造：隐藏键双改造 + KPlugin 补 zh_Hans 语言键。

    隐藏改造：加 X-KWin-Internal=true、Exclusive-Category 改 bmw-hidden ——
    19 个特效从「动效下拉」与「桌面特效列表」两个设置 UI 同时隐藏，
    运行时加载不受影响（KWin effectloader 不读 X-KWin-Internal）。
    语言键（i18n 2026-09-30）：Name/Description 的 zh_CN 主键（KWin 官方惯例，
    KPluginMetaData 按 zh_CN 查）+ zh_Hans 兼容键，KWin 与聚合页按系统语言取值；
    中译源自 BMW_ZH_META。
    首次修改前备份原文为 metadata.json.orig —— uninstall 还原的唯一依据；
    全部键均已就位 → 不写盘返回 False（幂等，语言键与隐藏键分别判断）。
    任何失败走 _die（退出码 2）。
    """
    meta = _meta_path(effect_dir)
    if not meta.exists():
        _die(f"metadata.json 不存在: {meta}")
    current = meta.read_text(encoding="utf-8")
    try:
        data = json.loads(current)
    except json.JSONDecodeError as exc:
        _die(f"metadata.json 不是合法 JSON: {meta}: {exc}")

    changed = False

    # 语言键补齐（幂等：zh_CN/zh_Hans 双键各查各补；未知 id 跳过不阻断隐藏改造）。
    # 双键依据：KWin 官方特效 metadata 中文键用 zh_CN（系统 /usr/share/kwin/effects
    # 实证 cube 等用 Name[zh_CN]、零个 zh_Hans），KPluginMetaData 按 zh_CN 查；zh_Hans
    # 保留给 KCM 手写 fallback 链与上游 po 惯例（本仓库 kcm.cpp effectDisplayName）。
    zh = BMW_ZH_META.get(Path(effect_dir).name)
    if zh:
        kplugin = data.setdefault("KPlugin", {})
        for key, value in (("Name[zh_CN]", zh[0]), ("Description[zh_CN]", zh[1]),
                           ("Name[zh_Hans]", zh[0]), ("Description[zh_Hans]", zh[1])):
            if key not in kplugin:
                kplugin[key] = value
                changed = True

    # 隐藏改造（幂等：两键均已就位则不改）
    if data.get("X-KWin-Internal") != "true" \
            or data.get("X-KWin-Exclusive-Category") != "bmw-hidden":
        data["X-KWin-Internal"] = "true"
        data["X-KWin-Exclusive-Category"] = "bmw-hidden"
        changed = True

    if not changed:
        return False  # 全部改造已完成，幂等返回

    backup = Path(str(meta) + ".orig")
    if not backup.exists():
        # 只在首次修改时备份，保留上游原文（重复 patch 不覆盖 .orig）
        backup.write_text(current, encoding="utf-8")

    meta.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return True


def restore_metadata(effect_dir) -> bool:
    """把 metadata.json 还原为 patch 前备份并删除 .orig。

    与 restore(main.js) 不同：无备份时返回 False 而非退出 —— 卸载流程对
    「从未 patch 过」的目录应无操作继续（幂等卸载），而非失败中止。
    """
    meta = _meta_path(effect_dir)
    backup = Path(str(meta) + ".orig")
    if not backup.exists():
        return False
    meta.write_text(backup.read_text(encoding="utf-8"), encoding="utf-8")
    backup.unlink()
    return True


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="向 KWin 特效 main.js 注入随机仲裁代码")
    parser.add_argument("--effect-dir", required=True, help="特效根目录（含 contents/code/main.js）")
    parser.add_argument("--effect-id", default="", help="特效 ID，如 kwin6_effect_fire（注入模式必填）")
    parser.add_argument("--pool", default="", help="参与随机的特效 ID，逗号分隔")
    parser.add_argument("--blacklist", default="", help="被剔除的特效 ID，逗号分隔")
    parser.add_argument("--restore", action="store_true", help="还原 main.js 为备份而非注入")
    parser.add_argument("--patch-metadata", action="store_true",
                        help="对 --effect-dir 执行 metadata 双改造（幂等）")
    parser.add_argument("--restore-metadata", action="store_true",
                        help="把 --effect-dir 的 metadata.json 还原为 .orig 备份")
    args = parser.parse_args(argv)

    if args.patch_metadata:
        patch_metadata(args.effect_dir)
    elif args.restore_metadata:
        restore_metadata(args.effect_dir)
    elif args.restore:
        restore(args.effect_dir)
    else:
        if not args.effect_id:
            _die("注入模式缺少 --effect-id")
        inject(args.effect_dir, args.effect_id, args.pool, args.blacklist)
    return 0


if __name__ == "__main__":
    sys.exit(main())
