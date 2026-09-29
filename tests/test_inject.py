# 注入器单元测试 —— python3 -m pytest tests/test_inject.py -v
#
# 覆盖两层契约：
#   1. Python 函数层（brief 的 5 个用例）—— 失败时抛 SystemExit(2)
#   2. CLI 层 —— 退出码 2 必须传到进程（Task 3/4 通过 CLI 消费本模块）
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "lib"))

from inject import inject, restore  # noqa: E402  —— 需先注入 sys.path

FIXTURE = ROOT / "tests" / "fixtures" / "main.js.sample"
ARBITER_SRC = ROOT / "lib" / "arbiter.js"


@pytest.fixture
def effect_dir(tmp_path) -> Path:
    """构造与真实安装一致的特效目录：<dir>/contents/code/main.js"""
    d = tmp_path / "kwin6_effect_fire"
    code = d / "contents" / "code"
    code.mkdir(parents=True)
    (code / "main.js").write_text(FIXTURE.read_text(encoding="utf-8"), encoding="utf-8")
    return d


@pytest.fixture
def main_path(effect_dir) -> Path:
    return effect_dir / "contents" / "code" / "main.js"


def read_main(effect_dir: Path) -> str:
    return (effect_dir / "contents" / "code" / "main.js").read_text(encoding="utf-8")


def write_main(effect_dir: Path, content: str) -> None:
    (effect_dir / "contents" / "code" / "main.js").write_text(content, encoding="utf-8")


def count_marker(src: str) -> int:
    return src.count("BMW_ARBITER_BEGIN")


def test_injection_adds_marker_and_keeps_syntax_valid(effect_dir, main_path):
    inject(str(effect_dir), "kwin6_effect_fire", pool="a,b", blacklist="b")
    src = read_main(effect_dir)
    assert "BMW_ARBITER_BEGIN" in src and "BMW_ARBITER_END" in src
    assert '"kwin6_effect_fire"' in src          # effect id 已固化（带引号的字面量）
    assert subprocess.run(["node", "--check", str(main_path)]).returncode == 0


def test_injection_is_idempotent(effect_dir):
    inject(str(effect_dir), "kwin6_effect_fire", pool="a,b", blacklist="b")
    first = read_main(effect_dir)
    inject(str(effect_dir), "kwin6_effect_fire", pool="a,b", blacklist="b")   # 重复执行
    assert read_main(effect_dir) == first        # 逐字节相同


def test_blacklist_change_rewrites_literal_only(effect_dir):
    inject(str(effect_dir), "id", pool="a,b,c", blacklist="b")
    inject(str(effect_dir), "id", pool="a,b,c", blacklist="b,c")
    after = read_main(effect_dir)
    assert count_marker(after) == 1             # 仍然只有一份
    assert 'BMW_BLACKLIST = ["b","c"]' in after  # 新值已写入
    assert 'BMW_BLACKLIST = ["b"]' not in after  # 旧值不残留


def test_restore_reverts_to_original(effect_dir, main_path):
    original = read_main(effect_dir)
    inject(str(effect_dir), "id", pool="a", blacklist="")
    restore(str(effect_dir))
    assert read_main(effect_dir) == original


def test_unmatched_structure_fails_loudly(effect_dir):
    write_main(effect_dir, "// 空文件，不含任何结构")
    with pytest.raises(SystemExit) as e:
        inject(str(effect_dir), "id", pool="a", blacklist="")
    assert e.value.code == 2                    # 明确失败，不静默跳过


def test_cli_returns_exit_code_2_on_unmatched_structure(effect_dir, capsys):
    """CLI 契约：结构不匹配 → 退出码 2 且原因写 stderr（Task 3/4 依赖）。"""
    write_main(effect_dir, "// 空文件，不含任何结构")
    proc = subprocess.run(
        [
            sys.executable,
            str(ROOT / "lib" / "inject.py"),
            "--effect-dir", str(effect_dir),
            "--effect-id", "id",
            "--pool", "a",
            "--blacklist", "",
        ],
        capture_output=True,
        text=True,
    )
    assert proc.returncode == 2
    assert proc.stderr.strip() != ""            # 必须有可读原因


def test_injection_contains_placeholder_gate(effect_dir):
    """调用行必须带开关闸：占位常量 + effects.isEffectLoaded(BMW_PLACEHOLDER_ID)。

    这是 Task 1 的 C++ 侧契约之外的注入产物契约：19 个 main.js 由 inject.py
    生成，闸是否接上只能靠产物字符串断言锁定（e2e 关态用例为运行时兜底）。
    """
    inject(str(effect_dir), "id", pool="a", blacklist="")
    src = read_main(effect_dir)
    assert 'const BMW_PLACEHOLDER_ID = "kwin6_effect_bmw_random"' in src
    assert "effects.isEffectLoaded(BMW_PLACEHOLDER_ID)" in src


def test_helper_block_contains_arbiter_source(effect_dir):
    """注入的 helper 必须与 lib/arbiter.js 逐字一致，避免两处实现漂移。"""
    inject(str(effect_dir), "id", pool="a", blacklist="")
    src = read_main(effect_dir)
    assert ARBITER_SRC.read_text(encoding="utf-8").strip() in src
