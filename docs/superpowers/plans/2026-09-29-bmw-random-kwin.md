# 随机特效包装层 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 构建一个不修改上游的 Burn-My-Windows 包装层，一次安装 19 个特效，并在每次窗口开/关时从黑名单过滤后的池中独立随机选取特效播放，配一个自定义 KCM 图形界面编辑黑名单。

**Architecture:** 构建期注入 —— `install.sh` 克隆上游、构建、解包到用户目录后，用 `lib/inject.py` 把 `lib/arbiter.js`（纯逻辑、可独立单测）内联进 19 份 `main.js`，注入的仲裁代码用 `window.setData(role, winner)` 在特效间先到先得地选出唯一 winner。KCM 以系统级路径安装，其 Apply 按钮通过 `QProcess` 调用免 sudo 的 `--apply-config` 重新注入并经 D-Bus 重载特效。

**Tech Stack:** Bash 5.3、Python 3.14（注入器）、JavaScript（仲裁逻辑，Node 26 单测）、CMake + Qt6 + KF6 6.30（KCM）、QML（KCM UI）

**Spec:** `docs/superpowers/specs/2026-09-29-bmw-random-kwin-design.md`

## Global Constraints

- **不修改上游源码**：只改安装到 `~/.local/share/kwin/effects/` 的副本；上游克隆目录本身不可被改动
- **黑名单方式，默认全部 19 个进池**；UI **勾选 = 加入黑名单 = 不参与随机**
- **open 与 close 各自独立随机**，role 分别为 `424242` / `424243`（【实测】与 KWin 内置 role `1`/`2`/`5`/`6` 无冲突）
- **KCM 装系统级** `/usr/lib/qt6/plugins/plasma/kcms/systemsettings/`（需 sudo，仅此一步）
- **`--apply-config` 必须完全免 sudo、完全非交互**，退出码语义明确，诊断走 stderr（KCM 要读）
- **黑名单真相源** `~/.config/burn-window-randomrc`，键 `Pool` / `Blacklist` / `ApplyScript`
- **`install.sh` 首装必须写 `kwinrc [Plugins]` 19 个 `kwin6_effect_*Enabled=true`**（否则重启后不加载）
- **池为空时不播放任何特效**
- 目标环境 Plasma 6.7.5 / KF6 6.30 / Qt6 / Wayland；QML 必须位于 `ui/` 目录
- 代码注释与输出**全部中文**；结论必须附可追溯依据，禁用猜测性表述

## Review Focus

以下为 spec 隐含、但最易让使用者踩坑的失败模式，每条在所属任务中有对应测试：

1. **上游 `main.js` 模板变化导致注入点失效** —— 注入器依赖结构匹配；若匹配失败却静默跳过，用户会得到"装了但不随机"的哑弹。期望：注入后每个目标文件必含标记块，且 `node --check` 语法通过。→ Task 2
2. **黑名单勾选全部 19 个（空池）** —— 期望不播放任何特效、不抛异常、不残留旧 winner。→ Task 1
3. **重复执行 `--apply-config` 导致注入代码叠加** —— 期望第二次注入结果与第一次逐字节相同。→ Task 2
4. **`sudo` 步骤失败留下半安装状态** —— 期望提权步骤排在最后且失败即中止，已写入的配置不误导后续 apply。→ Task 3
5. **KCM 的 Apply 子进程超时或失败时无反馈** —— 期望超时被检测、stderr 原文展示给用户、按钮状态恢复。→ Task 5

---

## File Structure

```
burn-window/
├── install.sh                    # 编排：克隆/构建/解包/注入/写kwinrc/写配置/装KCM；含 --apply-config
├── lib/
│   ├── arbiter.js                # 仲裁纯逻辑（可被 Node 单测，也被注入器内联进 main.js）
│   └── inject.py                 # 注入器：把 arbiter.js + 常量内联进单个 main.js（备份/幂等/还原）
├── kcm/
│   ├── CMakeLists.txt            # KF6 KCM 构建（已验证的写法见 spec 4.8）
│   ├── kcm.h / kcm.cpp           # 读配置 → 暴露属性；Apply → QProcess
│   ├── kcm_burnwindow.json       # 插件元数据
│   └── ui/main.qml               # 黑名单勾选列表（必须在 ui/ 下）
└── tests/
    ├── arbiter.test.mjs          # Node 单测（node:test）
    ├── test_inject.py            # 注入器单测（含 node --check 语法门禁）
    └── fixtures/main.js.sample   # 取自上游的真实结构样本
```

**分界依据**：`arbiter.js` 是唯一含随机/仲裁算法的文件，独立于文件 IO，因此可纯函数测试；`inject.py` 只负责文本定位与写入，不含算法；`install.sh` 只编排，不实现逻辑；KCM 只读写配置与起子进程，不碰特效文件。

---

### Task 1: 仲裁核心 `lib/arbiter.js`

**Files:**
- Create: `lib/arbiter.js`
- Test: `tests/arbiter.test.mjs`

**Interfaces:**
- Consumes: 无（纯逻辑，只依赖注入时传入的常量）
- Produces（Task 2 注入时内联，Task 7 端到端依赖其行为）:
  - `bmwPickWinner(pool: string[], blacklist: string[], rng: () => number): string | null` —— 过滤黑名单后随机取一个；池空或全被过滤返回 `null`
  - `bmwShouldPlay(window: object, roleId: number, myEffectId: string, pool: string[], blacklist: string[], rng: () => number): boolean` —— 先到先得：`window.data(roleId)` 为空则抽签并 `window.setData(roleId, winner)`，否则复用已存 winner；返回 `winner === myEffectId`
  - `bmwCleanup(window: object, roleId: number): void` —— `window.setData(roleId, null)`

- [ ] **Step 1: 写失败测试 `tests/arbiter.test.mjs`**

用 `node:test`，mock `window`（`data`/`setData` 存于普通 Map）与可控 `rng`：

```js
test("黑名单过滤：被剔除的特效不会当选", () => {
  const winner = bmwPickWinner(["a","b","c"], ["b"], () => 0.99);
  assert.notEqual(winner, "b");
});

test("先到先得：第二个调用者复用第一个抽的 winner", () => {
  const w = fakeWindow();
  const rng = sequence(0.0, 0.0);           // 第一次抽第 1 项
  assert.equal(bmwShouldPlay(w, 424242, "a", ["a","b"], [], rng), true);
  assert.equal(bmwShouldPlay(w, 424242, "b", ["a","b"], [], rng), false); // 不再抽签
});

test("open/close role 隔离：关闭时用 424243 重新抽签", () => {
  const w = fakeWindow();
  bmwShouldPlay(w, 424242, "a", ["a","b"], [], sequence(0.0));
  assert.equal(w.data(424243), null);       // 424242 的结果不影响 424243
});

test("空池：返回 null，任何特效都不播放", () => {
  const w = fakeWindow();
  assert.equal(bmwPickWinner([], [], () => 0.5), null);
  assert.equal(bmwShouldPlay(w, 424242, "a", [], [], () => 0.5), false);
  assert.equal(w.data(424242), null);       // 同一个 w，断言未写入有效 winner
});

test("全量黑名单等价于空池", () => {
  assert.equal(bmwPickWinner(["a","b"], ["a","b"], () => 0.5), null);
});

test("cleanup 后重新抽签", () => {
  const w = fakeWindow();
  bmwShouldPlay(w, 424242, "a", ["a","b"], [], sequence(0.0));
  bmwCleanup(w, 424242);
  assert.equal(w.data(424242), null);
});
```

- [ ] **Step 2: 运行确认失败**

Run: `node --test tests/arbiter.test.mjs`
Expected: FAIL（模块不存在）

- [ ] **Step 3: 实现 `lib/arbiter.js`**

以 `function` 声明（不加 `export` —— 注入器要内联进无模块系统的 effect 上下文）。`bmwShouldPlay` 内联实现 `bmwPickWinner` 的逻辑，避免注入后需要跨文件依赖。

- [ ] **Step 4: 运行测试确认通过**

Run: `node --test tests/arbiter.test.mjs`
Expected: PASS，6/6

- [ ] **Step 5: 提交**

```bash
git add lib/arbiter.js tests/arbiter.test.mjs
git commit -m "feat: 仲裁核心 bmwPickWinner/bmwShouldPlay（含黑名单过滤与先到先得）"
```

---

### Task 2: 注入器 `lib/inject.py`

**Files:**
- Create: `lib/inject.py`
- Test: `tests/test_inject.py`
- Test fixture: `tests/fixtures/main.js.sample`

**Interfaces:**
- Consumes: `lib/arbiter.js`（Task 1，作为注入模板源）
- Produces（Task 3/4 调用）:
  - CLI：`python3 lib/inject.py --effect-dir <dir> --effect-id <id> --pool <csv> --blacklist <csv> [--restore]`
  - 成功退出码 `0`；目标文件不匹配结构则退出码 `2` 并把原因写 stderr
  - 副作用：`<dir>/contents/code/main.js` 被改写，原文件备份为 `<dir>/contents/code/main.js.orig`

- [ ] **Step 1: 准备 fixture 并写失败测试 `tests/test_inject.py`**

fixture 取真实上游结构（含 `class BurnMyWindows...Effect`、`slotWindowAdded`、`slotWindowClosed`、`new BurnMyWindows...Effect();`）：

```python
def test_injection_adds_marker_and_keeps_syntax_valid(tmp_path):
    inject(effect_dir, "kwin6_effect_fire", pool="a,b", blacklist="b")
    src = read_main(effect_dir)
    assert "BMW_ARBITER_BEGIN" in src and "BMW_ARBITER_END" in src
    assert "kwin6_effect_fire" in src          # effect id 已固化
    assert subprocess.run(["node","--check",str(main_path)]).returncode == 0

def test_injection_is_idempotent(tmp_path):
    inject(effect_dir, "kwin6_effect_fire", pool="a,b", blacklist="b")
    first = read_main(effect_dir)
    inject(effect_dir, "kwin6_effect_fire", pool="a,b", blacklist="b")   # 重复执行
    assert read_main(effect_dir) == first        # 逐字节相同

def test_blacklist_change_rewrites_literal_only(tmp_path):
    inject(effect_dir, "id", pool="a,b,c", blacklist="b")
    before = read_main(effect_dir)
    inject(effect_dir, "id", pool="a,b,c", blacklist="b,c")
    after = read_main(effect_dir)
    assert count_marker(after) == 1             # 仍然只有一份
    assert '"b,c"' in after                      # 黑名单字面量已更新

def test_restore_reverts_to_original(tmp_path):
    original = read_main(effect_dir)
    inject(effect_dir, "id", pool="a", blacklist="")
    restore(effect_dir)
    assert read_main(effect_dir) == original

def test_unmatched_structure_fails_loudly(tmp_path):
    write_main(effect_dir, "// 空文件，不含任何结构")
    with pytest.raises(SystemExit) as e:
        inject(effect_dir, "id", pool="a", blacklist="")
    assert e.value.code == 2                    # 明确失败，不静默跳过
```

- [ ] **Step 2: 运行确认失败**

Run: `python3 -m pytest tests/test_inject.py -v`
Expected: FAIL（模块不存在）

- [ ] **Step 3: 实现 `lib/inject.py`**

要点（签名已定，实现者写正文）：

- 用**锚点定位**而非脆弱的行号：插入 `slotWindowAdded`/`slotWindowClosed` 函数体首行之前（正则匹配函数签名后第一个 `{`）；仲裁 helper 插到 `"use strict";` 之后
- 幂等：先检测 `BMW_ARBITER_BEGIN`，存在则**整块替换**而非追加
- 备份：仅当 `.orig` 不存在时创建（保留首次原始副本）
- 校验：写入后 `node --check` 失败即回滚并退出码 `2`

- [ ] **Step 4: 运行测试确认通过**

Run: `python3 -m pytest tests/test_inject.py -v`
Expected: PASS，5/5

- [ ] **Step 5: 提交**

```bash
git add lib/inject.py tests/test_inject.py tests/fixtures/main.js.sample
git commit -m "feat: 注入器（锚点定位/幂等/备份还原/语法门禁）"
```

---

### Task 3: `install.sh` 首次安装主流程

**Files:**
- Create: `install.sh`
- Test: `tests/test_install.sh`

**Interfaces:**
- Consumes: `lib/inject.py`（Task 2 的 CLI）
- Produces（Task 4 在同一文件追加 `--apply-config`；Task 5 的 KCM 读取）:
  - `install.sh`（无参）：完整安装；`--dry-run`：只打印将执行的动作，不落盘
  - 写入 `~/.config/burn-window-randomrc`：`Pool=<19个ID>`、`Blacklist=`（空）、`ApplyScript=~/.local/libexec/burn-window-apply-config.sh`
  - 装 KCM 到 `/usr/lib/qt6/plugins/plasma/kcms/systemsettings/kcm_burnwindow.so`（唯一需 sudo 的步骤）

- [ ] **Step 1: 写失败测试 `tests/test_install.sh`**

```bash
test_dry_run_writes_nothing() {
  run install.sh --dry-run --prefix "$TMP"
  assert_not_exists "$TMP/config/burn-window-randomrc"
  assert_output_contains "kwin6_effect_fire"        # 打印了池成员
}

test_first_run_writes_config_with_all_19_pool_members() {
  run install.sh --prefix "$TMP" --skip-sudo --skip-build --skip-kwinrc
  local pool=$(kreadconfig6 --file "$TMP/burn-window-randomrc" --group General --key Pool)
  assert_eq "$(echo "$pool" | tr ',' '\n' | wc -l)" "19"
  assert_empty "$(kreadconfig6 ... --key Blacklist)"
}

test_sudo_step_is_last_and_failure_aborts() {
  # 提权步骤必须排在最后；模拟其失败后配置文件不被写入
  run install.sh --prefix "$TMP" --skip-build --fail-sudo
  assert_exit_code_nonzero
  assert_not_exists "$TMP/config/burn-window-randomrc"
}

test_kwinrc_enabled_written_for_all_19() {
  run install.sh --prefix "$TMP" --skip-sudo --skip-build
  assert_eq "$(grep -c 'kwin6_effect_.*Enabled=true' "$TMP/kwinrc")" "19"
}
```

> 测试通过 `--prefix`、`--skip-build`、`--skip-sudo` 等参数隔离副作用（这些是为可测试性而设的正式参数，不是 test-only 后门）。
>
> **关于 sudo**：`test_sudo_step_is_last_and_failure_aborts` 与 Task 5 的 `test_kcmshell6_loads_by_name` 需要提权。**plan 与测试代码中不得硬编码密码**；执行时由运行者提供凭据（`SUDO_ASKPASS` 或已缓存的 `sudo -v`），凭据不可得时这两个用例标记 SKIP 并在输出中注明，不得假阴性通过。

- [ ] **Step 2: 运行确认失败**

Run: `bash tests/test_install.sh`
Expected: FAIL（`install.sh` 不存在）

- [ ] **Step 3: 实现 `install.sh` 主流程**

动作顺序（**顺序本身是需求**，来自 spec 7.2 #4）：

1. 检查依赖（`cmake`/`ninja`/`git`/`kreadconfig6`/`node`），缺失即中止
2. 克隆上游（镜像 `https://ghfast.top/https://github.com/Schneegans/Burn-My-Windows.git`）到 `upstream/`（已在 `.gitignore`）
3. `kwin/build.sh` 构建合集包 → 解包到 `~/.local/share/kwin/effects/`
4. 对 19 个特效逐个调 `lib/inject.py`（池成员清单从构建产物的 `metadata.json` 现场提取，不硬编码）
5. 写 `kwinrc [Plugins]` 19 个 `Enabled=true`（先备份 `kwinrc.bak.<时间戳>`）
6. 写 `burn-window-randomrc`（`Pool`/`Blacklist`/`ApplyScript`）
7. 把 `--apply-config` 逻辑复制为 `~/.local/libexec/burn-window-apply-config.sh` 并 `chmod +x`
8. **最后**才 `sudo install` KCM `.so`；此步失败 → 打印已保留的用户级安装，退出码非 0

- [ ] **Step 4: 运行测试确认通过**

Run: `bash tests/test_install.sh`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add install.sh tests/test_install.sh
git commit -m "feat: install.sh 首装流程（提权步骤最后、失败即中止）"
```

---

### Task 4: `install.sh --apply-config` 子命令

**Files:**
- Modify: `install.sh`（追加子命令分发与实现）
- Test: `tests/test_apply_config.sh`

**Interfaces:**
- Consumes: `install.sh` 已写入的 `burn-window-randomrc`（`Pool`/`Blacklist`）
- Produces: `install.sh --apply-config` —— **免 sudo、完全非交互**；Task 5 的 KCM 以 `QProcess` 调用此命令（通过配置里的 `ApplyScript=`）

- [ ] **Step 1: 写失败测试 `tests/test_apply_config.sh`**

```bash
test_apply_rereads_blacklist_and_reinjects() {
  # 预置：已注入黑名单为空的 main.js
  install_fixture
  kwriteconfig6 --file "$CFG" --group General --key Blacklist "kwin6_effect_fire"
  run apply_config
  assert_exit_code 0
  assert_file_contains main_js '"kwin6_effect_fire"'   # 黑名单字面量已进入注入块
}

test_apply_is_idempotent() {
  apply_config; cp "$MAIN" "$TMP/first"
  apply_config
  assert_files_identical "$TMP/first" "$MAIN"
}

test_apply_reloads_all_19_effects_and_reports_failures_on_stderr() {
  apply_config 2>"$TMP/err"
  assert_eq "$(loaded_bmw_count)" "19"
  # 单个 loadEffect 失败不中断流程，但必须出现在 stderr
  assert_output_contains "$TMP/err" "loadEffect 失败" || true
}

test_apply_is_non_interactive() {
  # stdin 关闭时不得挂起等待输入
  run bash -c 'apply_config < /dev/null'
  assert_exit_code 0
  assert_not_timed_out
}

test_apply_refuses_when_config_missing() {
  # 【实测】kreadconfig6 对不存在的键返回空且退出码 0 ——
  # 若不校验文件存在性，配置缺失会被静默当成"空黑名单=全部进池"
  rm -f "$CFG"
  run apply_config
  assert_exit_code_nonzero
  assert_output_contains_stderr "配置文件不存在"     # 不得静默继续
  assert_file_unchanged "$MAIN"                     # 不得用默认值覆盖已注入内容
}
```

- [ ] **Step 2: 运行确认失败**

Run: `bash tests/test_apply_config.sh`
Expected: FAIL（子命令未实现）

- [ ] **Step 3: 实现 `--apply-config`**

流程：**先校验 `burn-window-randomrc` 存在，缺失即报错退出（退出码非 0，原因写 stderr）** → `kreadconfig6` 读 `Pool`/`Blacklist` → 对 19 个特效调 `lib/inject.py`（更新字面量）→ 经 `qdbus6 org.kde.KWin /Effects org.kde.kwin.Effects.<load|unload>Effect` 逐个重载 → 退出码 0；任一注入失败则退出码非 0 并写 stderr。

> 【实测】`kreadconfig6` 对**不存在的键**返回空字符串且**退出码 0**，无法用退出码区分"键缺失"与"值为空" —— 因此文件存在性必须单独校验，不能依赖读取结果。

> D-Bus 接口速查（【实测】）：服务 `org.kde.KWin`、路径 `/Effects`、**接口 `org.kde.kwin.Effects`（小写）**；`loadedEffects` 是**属性**（`qdbus6 ... org.kde.kwin.Effects.loadedEffects`），用 `property` 子命令会报错。

- [ ] **Step 4: 运行测试确认通过**

Run: `bash tests/test_apply_config.sh`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add install.sh tests/test_apply_config.sh
git commit -m "feat: --apply-config 子命令（免sudo、非交互、D-Bus重载）"
```

---

### Task 5: KCM C++ 侧（含 Apply 子进程）

**Files:**
- Create: `kcm/CMakeLists.txt`
- Create: `kcm/kcm.h`
- Create: `kcm/kcm.cpp`
- Create: `kcm/kcm_burnwindow.json`
- Test: `tests/test_kcm_build.sh`

**Interfaces:**
- Consumes: `~/.config/burn-window-randomrc`（Task 3 写入的 `Pool`/`Blacklist`/`ApplyScript`）
- Produces（Task 6 的 QML 消费）:
  - `Q_PROPERTY(QVariantList pool READ pool CONSTANT)` —— `[{effectId, displayName}]`
  - `Q_PROPERTY(QStringList blacklist READ blacklist NOTIFY blacklistChanged)`
  - `Q_INVOKABLE void toggleBlacklist(const QString &effectId, bool add)`
  - Apply：`QProcess` 启动 `ApplyScript`，`waitForFinished` 带 **15000ms 超时**；非 0 或超时时把 stderr/`QProcess::errorString()` 存入可读属性供 QML 展示

- [ ] **Step 1: 写失败测试 `tests/test_kcm_build.sh`**

```bash
test_build_produces_so() {
  cmake -S kcm -B "$TMP/build" -G Ninja && cmake --build "$TMP/build"
  assert_exists "$TMP/build/bin/plasma/kcms/systemsettings/kcm_burnwindow.so"
}

test_kcmshell6_loads_by_name() {
  sudo_install_so
  systemsettings --list | grep -q "kcm_burnwindow"        # 不带 QT_PLUGIN_PATH
  assert_dlopen "kcm_burnwindow"                            # /proc/<pid>/maps
}

test_apply_subprocess_failure_shows_stderr_and_restores_button() {
  # 把 ApplyScript 指向一条必失败命令
  kwriteconfig6 --file burn-window-randomrc --group General --key ApplyScript /bin/false
  启动 KCM → 触发 apply → 读 QML 暴露的错误属性
  assert_contains "applyOutput" 非空
  assert_enabled true                                       # 按钮已恢复
}
```

- [ ] **Step 2: 运行确认失败**

Run: `bash tests/test_kcm_build.sh`
Expected: FAIL

- [ ] **Step 3: 实现 KCM C++ 与 CMake**

三个已验证的坑（**必须照做**，见 spec 4.6/4.8）：

- `KQuickConfigModule` 构造函数是 **`protected`** → 必须 public 显式转发，**不得**用 `using KQuickConfigModule::KQuickConfigModule;`
- 末尾必须 `#include "kcm.moc"`
- 链接 `KF6::KCMUtilsQuick`（非 `KF6::KCMUtils`）；CMake 中 `find_package(ECM 6.0.0 ...)` **必须带版本号**，且 `find_package(Qt6)` **必须早于** `include(KDEInstallDirs6)`

- [ ] **Step 4: 运行测试确认通过**

Run: `bash tests/test_kcm_build.sh`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add kcm/ tests/test_kcm_build.sh
git commit -m "feat: KCM C++（配置读取、属性暴露、Apply 子进程与超时处理）"
```

---

### Task 6: KCM QML 界面

**Files:**
- Create: `kcm/ui/main.qml`
- Test: `tests/test_kcm_qml.sh`

**Interfaces:**
- Consumes: Task 5 的 `pool` / `blacklist` / `toggleBlacklist` / 错误输出属性
- Produces: 无下游（用户交互终点）

- [ ] **Step 1: 写失败测试 `tests/test_kcm_qml.sh`**

```bash
test_qml_renders_probe_to_journal() {
  在 main.qml 加 Component.onCompleted: console.log("BMW_KCM_QML_LOADED")
  启动 systemsettings kcm_burnwindow
  assert_journal_contains "BMW_KCM_QML_LOADED"
  assert_journal_contains "qrc:/kcm/kcm_burnwindow/main.qml"   # QRC 路径正确
}

test_checkbox_checked_reflects_blacklist() {
  kwriteconfig6 ... --key Blacklist "kwin6_effect_fire"
  启动 KCM → 断言 QML 属性绑定结果：fire 项 checked=true，其余 false
}

test_all_19_items_rendered() {
  断言 QML model 数量 == Pool 长度 == 19
}
```

- [ ] **Step 2: 运行确认失败**

Run: `bash tests/test_kcm_qml.sh`
Expected: FAIL

- [ ] **Step 3: 实现 `kcm/ui/main.qml`**

勾选语义（**需求方向，不可反**）：`checked: kcm.blacklist.includes(model.effectId)` —— 勾选 = 在黑名单 = 不参与随机；顶部说明文字写明该语义；默认 19 项全不勾。

- [ ] **Step 4: 运行测试确认通过**

Run: `bash tests/test_kcm_qml.sh`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add kcm/ui/main.qml tests/test_kcm_qml.sh
git commit -m "feat: KCM 黑名单勾选界面（勾选=剔除语义）"
```

---

### Task 7: 端到端验证

**Files:**
- Create: `tests/test_e2e.sh`

**Interfaces:**
- Consumes: Task 1-6 全部产物
- Produces: 可发布的验收结论

- [ ] **Step 1: 写端到端测试 `tests/test_e2e.sh`**

**窗口开/关的自动化方法**（【实测】本会话已验证可行）：后台以 50ms 间隔轮询 `qdbus6 org.kde.KWin /Effects org.kde.kwin.Effects.activeEffects` 采样，同时 `kwrite &` 启动（触发 open）→ `sleep 4` → `kill -TERM`（触发 close）。单轮约 8 秒，采样数组中匹配到 `kwin6_effect_*` 的项即为当轮 winner。

```bash
test_full_install_then_random_distribution() {
  install.sh --skip-sudo
  assert_eq "$(loaded_bmw_count)" "19"
  连续开/关窗口 20 次，采样 activeEffects
  assert_true "抽中的特效 ∈ 池 \ 黑名单"
}

test_open_and_close_are_independent() {
  统计 open 与 close 各自抽中的特效，断言二者不被绑定为同一项
}

test_blacklist_excludes_effect() {
  kwriteconfig6 ... Blacklist "kwin6_effect_fire" && apply_config
  连续 20 次开窗 → assert "kwin6_effect_fire 从未出现在 activeEffects"
}

test_all_blacklisted_plays_nothing() {
  Blacklist=全部 19 个 && apply_config
  开/关窗 10 次 → assert "activeEffects 不含任何 kwin6_effect_*"
}

test_role_values_do_not_collide_with_builtin() {
  # 【实测】内置 role 为 1/2/5/6，自定义 424242/424243 必须仍然无冲突
  注入探测 → 断言 Effect.WindowAddedGrabRole !== 424242 且 !== 424243
}
```

- [ ] **Step 2: 运行确认失败**

Run: `bash tests/test_e2e.sh`
Expected: FAIL（未安装）

- [ ] **Step 3: 执行完整安装并运行**

Run: `bash tests/test_e2e.sh`
Expected: PASS，5/5

- [ ] **Step 4: 提交**

```bash
git add tests/test_e2e.sh
git commit -m "test: 端到端验收（随机分布、黑名单生效、空池、role 冲突）"
```

---

## Self-Review 记录

**检查项与修复**（自查清单，非派发 subagent）：

1. **Spec 覆盖**：需求 1.1 的 5 项分别落在 Task 3（装 19 个）、Task 1+7（随机）、Task 1（open/close 独立）、Task 5+6（KCM 界面）；约束 1.2 全部进入 Global Constraints；spec 7.2 的 4 个边界行为分别由 Task 1（空池）、Task 3（kwinrc）、Task 7（多屏=范围外故不测）、Task 3 Step 3（构建失败中止）覆盖。**无缺口**。
2. **Step 扫描**：每步只含一个可检查动作；代码块仅出现在签名与测试无法确定的算法处（`inject.py` 锚点策略）。
3. **类型一致性**：`bmwPickWinner/bmwShouldPlay/bmwCleanup`（Task 1）→ Task 2 内联同一份源；`pool`/`blacklist`/`toggleBlacklist`（Task 5）→ Task 6 引用同名；CLI 参数名在 Task 2/3/4 间一致。**发现并修复**：Task 1 空池测试原先两次调用 `fakeWindow()` 导致断言作用于不同对象，已改为持有同一实例。
4. **Review Focus**：5 条均有对应测试（1→Task 2 Step 1、2→Task 1 Step 1、3→Task 2 Step 1、4→Task 3 Step 1、5→Task 5 Step 1）。
5. **比例**：plan 约为 spec 的 0.7 倍；代码块主要是测试断言，实现体以签名+要点描述。

**写入后追加验证的 3 个假设与 3 处补充**：

| # | 动作 | 结果 |
|---|---|---|
| 1 | 实测 `kreadconfig6/kwriteconfig6 --file <绝对路径>` | ✅ 读写可用，写入保留其他键 —— Task 3/4 测试假设成立 |
| 2 | 实测 `node --check` 校验 `main.js` | ✅ 返回 0 —— Task 2 语法门禁成立 |
| 3 | 实测**读不存在的键** | ⚠️ **返回空 + 退出码 0** —— 已补 Task 4：`apply-config` 必须先校验配置文件存在性，否则配置缺失会被静默当成"空黑名单=全进池"；新增对应用例 |
| 4 | — | 已补 Task 3/5：**sudo 凭据不得硬编码进 plan 或测试**，不可得时标记 SKIP 而非假阴性通过 |
| 5 | — | 已补 Task 7：窗口开/关的自动化方法（50ms 轮询 `activeEffects` + `kwrite`/`kill -TERM`，【实测】本会话验证可行） |
