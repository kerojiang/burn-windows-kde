# 随机特效聚合入口 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 19 个 BMW 特效从 KDE 动效下拉隐藏，代之以单条目「随机特效 [Burn-My-Windows]」+ 齿轮打开的聚合配置页（19 项勾选 + 全参数自渲染编辑），下拉为唯一总开关、完全遵循 KDE。

**Architecture:** 新增占位特效占据下拉条目（metadata 指向我方 KCM）；19 个经 metadata 双改造从两个设置 UI 隐藏但**常驻加载**（用户实测 5.8 MB 后确认）；仲裁逻辑以 `enabled` 参数同步查询占位加载态决定是否播放；聚合页自渲染（读 main.xml 类型动态生成控件），勾选反转为「勾上=参与」、内部仍以 `Blacklist = 未勾选集合` 反向映射。

**Tech Stack:** bash + python3（注入/安装编排）、JavaScript（KWin effect 仲裁）、C++17/Qt6/KF6 KQuickConfigModule + QML（聚合页）、bash 测试 + node:test + pytest。

**Spec:** `docs/superpowers/specs/2026-09-29-bmw-random-entry-design.md`（计划的一切取值以 spec 为准；执行者应先读 spec）

## Global Constraints

- 不修改上游源码：只改构建/安装产物（占位特效与 metadata patch 均属安装产物）
- `sudo` 凭据只经 `SUDO_PASSWORD` 环境变量注入，**任何文件不得硬编码**
- TDD 铁律：每项改动先失败测试 → 看到 RED → 最小实现 → GREEN；每任务一次 commit
- 完成门槛 = 全量 8 套回归全绿：`node --test tests/arbiter.test.mjs`、`python3 -m pytest tests/test_inject.py -q`、`bash tests/test_{install,apply_config,uninstall}.sh`、`env SUDO_PASSWORD=1 bash tests/test_kcm_{build,qml}.sh`、`bash tests/test_e2e.sh`
- e2e 必须最后**单独串行**（独占真实 KWin D-Bus；不与任何操作真实 KWin 的测试并行）
- 占位 id = `kwin6_effect_bmw_random`；显示名 = `随机特效 [Burn-My-Windows]`（D9）；`EnabledByDefault=false`
- 勾选语义：**勾上 = 参与随机**（D3；`Blacklist = 未勾选集合`，配置格式不变）
- 开关唯一真相源 = KDE 写的 `[Plugins] kwin6_effect_bmw_randomEnabled`；聚合页**无开关控件**，只读展示（D4/D6）
- 19 个常驻加载：`[Plugins]` 19 键 `Enabled=true` 维持不改（实测驻留 5.8 MB，spec §3.5-1/§8）
- 19 个特效必须保持可加载、可随机播放（隐藏仅针对两个设置 UI，运行时不读 `X-KWin-Internal`）

## Review Focus

以下 5 项是 spec 隐含、最可能先咬人的失败模式，各归属任务的测试已就位：

1. **占位目录混入池成员遍历** → `do_inject`/apply 按目录遍历，占位 main.js 无 BMW 锚点，`inject.py` 会 `_die` 中止安装/apply。归属 Task 4：断言安装成功且 `--apply-config` 退出 0、注入数=19、占位 main.js 不含 `BMW_ARBITER`。
2. **metadata patch 破坏 JSON 或 KWin 拒绝加载** → patch 后若 JSON 非法，KWin 静默跳过特效。归属 Task 3（`json.load` 解析断言 + 字段断言 + 幂等）与 Task 9（e2e：patch 后 19 个仍全部 loaded）。
3. **开关关闭态写入残留 winner** → 关闭时若仍抽签写 `window.setData`，重开后会复用陈旧结果。归属 Task 1：断言 `enabled=false` 时返回 false 且 `window.data(role)` 保持 null；Task 9：开→关→开轮换后随机性仍成立。
4. **参数写入组名/type 与 KConfigXT 不符** → 写错组则上游 `readConfig`（锁死 `[Effect-<id>]`）读不到，改了不生效。归属 Task 8：写入后 `kreadconfig6 --group Effect-<id>` 读回断言 + `reconfigureEffect` 调用诊断断言。
5. **双入口残留 / 卸载残留** → 旧 systemsettings 落点未删则两入口并存（违反 D8）；占位键/占位目录/`.orig` 不在 Pool 内，既有清理收集不到。归属 Task 4（旧落点删除断言）与 Task 5（占位键 + 占位目录 + `.orig` + 两落点 KCM 清理断言）。

## File Structure

```
placeholder/kwin6_effect_bmw_random/     Create  C1 占位特效模板
  metadata.json                                   下拉条目 + 齿轮指向聚合页
  contents/code/main.js                           空实现（零动画，仅作状态标识）
lib/inject.py                            Modify  C2：patch/restore metadata + 调用行加 enabled + 占位常量
lib/arbiter.js                           Modify  bmwShouldPlay 第 7 参 enabled 开关闸
install.sh                               Modify  C4：占位写入/patch/跳过/KCM 新落点+旧落点清理
uninstall.sh                             Modify  C5：对称清理
kcm/kcm.h / kcm/kcm.cpp                  Modify  C3：pool 模型扩展 + randomLoaded + 参数读写 + reconfigure
kcm/ui/main.qml                          Modify  C3：聚合页（勾选反转 + 参数面板）
tests/arbiter.test.mjs                   Modify  开关闸单测
tests/test_inject.py                     Modify  patch/restore 单测 + 注入产物断言
tests/test_install.sh                    Modify  占位/patch/跳过/幂等/落点断言
tests/test_uninstall.sh                  Modify  对称清理断言
tests/test_kcm_build.sh                  Modify  pool 模型/参与映射/参数写入断言
tests/test_kcm_qml.sh                    Modify  聚合页探针断言
tests/test_e2e.sh                        Modify  开关链路用例
```

---

### Task 1: 仲裁开关闸（enabled 参数）

**Files:**
- Modify: `lib/arbiter.js`（`bmwShouldPlay` 签名与入口）
- Modify: `lib/inject.py`（`_build_block` 常量行、`_open_call`/`_close_call` 生成的调用行）
- Test: `tests/arbiter.test.mjs`、`tests/test_inject.py`

**Interfaces:**
- Consumes: KWin effect JS 全局 `effects.isEffectLoaded(id)`（Q_SCRIPTABLE，effecthandler.h:1075；注入上下文已注入 `effects` 对象）
- Produces: `bmwShouldPlay(window, roleId, myEffectId, pool, blacklist, rng, enabled) -> boolean` —— 第 7 参 `enabled: boolean`，false 时**直接返回 false 且不写任何 winner**。注入产物新增常量 `const BMW_PLACEHOLDER_ID = "kwin6_effect_bmw_random";`，调用行为 `bmwShouldPlay(window, BMW_ROLE_OPEN, BMW_MY_EFFECT_ID, BMW_POOL, BMW_BLACKLIST, Math.random, effects.isEffectLoaded(BMW_PLACEHOLDER_ID))`（close 同理）。后续任务依赖：注入的 19 个 main.js 必须含此常量与调用形态。

- [ ] **Step 1: 写失败测试**

`tests/arbiter.test.mjs` 追加（沿用现有 `fakeWindow`/`sequence`/`OPEN_ROLE` 工具）：

```js
test("开关闸：enabled=false 不播放且不写 winner", () => {
  const w = fakeWindow();
  assert.equal(bmwShouldPlay(w, OPEN_ROLE, "a", ["a", "b"], [], sequence(0), false), false);
  assert.equal(w.data(OPEN_ROLE), null); // 关闭态不得留下残留 winner
});
test("开关闸：enabled=true 正常抽签", () => {
  const w = fakeWindow();
  assert.equal(bmwShouldPlay(w, OPEN_ROLE, "a", ["a", "b"], [], sequence(0), true), true);
  assert.equal(w.data(OPEN_ROLE), "a");
});
test("开关关→开：关闭态未写 winner，开启后按 rng 重新抽", () => {
  const w = fakeWindow();
  bmwShouldPlay(w, OPEN_ROLE, "a", ["a", "b"], [], sequence(0, 1), false);
  assert.equal(bmwShouldPlay(w, OPEN_ROLE, "b", ["a", "b"], [], undefined, true), true);
  assert.equal(w.data(OPEN_ROLE), "b");
});
```

`tests/test_inject.py` 追加 2 条断言（注入产物字符串检查，风格沿用现有用例）：产物含 `const BMW_PLACEHOLDER_ID = "kwin6_effect_bmw_random"`；产物含 `effects.isEffectLoaded(BMW_PLACEHOLDER_ID)`。

- [ ] **Step 2: 跑测试确认失败**

Run: `node --test tests/arbiter.test.mjs 2>&1 | tail -5`；`python3 -m pytest tests/test_inject.py -q`
Expected: arbiter 3 个新用例 FAIL（多余参数不改变行为 → 第 1 例实际返回 true / 写入 winner）；inject 2 断言 FAIL（常量不存在）

- [ ] **Step 3: 实现**

`lib/arbiter.js`：`bmwShouldPlay` 加第 7 参 `enabled`，函数体**第一行** `if (!enabled) return false;`（在 eligible 计算与 `window.data` 读取之前，保证关闭态零写入）。文件头注释补一行：开关态经参数传入（外部符号一律走参数，遵守文件头约定）。

`lib/inject.py`：
- `_build_block` 的常量区（`BMW_ROLE_CLOSE` 之后）加 `const BMW_PLACEHOLDER_ID = "kwin6_effect_bmw_random";`
- `_open_call`/`_close_call` 的调用行尾加第 7 参：`..., Math.random, effects.isEffectLoaded(BMW_PLACEHOLDER_ID))`

- [ ] **Step 4: 跑测试确认通过**

Run: 同 Step 2
Expected: arbiter `pass 10+3 / fail 0`；inject `passed`

- [ ] **Step 5: Commit**

```bash
git add lib/arbiter.js lib/inject.py tests/arbiter.test.mjs tests/test_inject.py
git commit -m "feat(arbiter): 开关闸 enabled 参数 —— 占位未加载时不播放不写 winner"
```

---

### Task 2: 占位特效模板

**Files:**
- Create: `placeholder/kwin6_effect_bmw_random/metadata.json`
- Create: `placeholder/kwin6_effect_bmw_random/contents/code/main.js`
- Test: `tests/test_install.sh`（头部新增静态段，不依赖安装运行）

**Interfaces:**
- Produces: 模板目录（Task 4 的 `do_placeholder` 整目录复制到 `$EFFECTS_DIR/kwin6_effect_bmw_random`）。metadata 必含字段（Task 4/9 的断言依据）：`KPlugin.Id=kwin6_effect_bmw_random`、`KPlugin.Name=随机特效 [Burn-My-Windows]`、`KPlugin.EnabledByDefault=false`、`KPlugin.Category=Window Open/Close Animation`、`X-KWin-Exclusive-Category=toplevel-open-close-animation`、`X-KDE-ConfigModule=kcm_burnwindow`、`X-Plasma-API=javascript`、`X-Plasma-MainScript=code/main.js`、`KPackageStructure=KWin/Effect`。`main.js` 为**空文件**（V1 待验证：空实现能否加载，由 Task 9 e2e 实测）。

- [ ] **Step 1: 写失败测试**

`tests/test_install.sh` 在 `setup()` 之前加静态段（不调用 setup，直接断言模板文件）：

```bash
echo "=== test_placeholder_template ==="
TEMPLATE="$ROOT/placeholder/kwin6_effect_bmw_random"
assert_exists "$TEMPLATE/metadata.json" "占位 metadata.json 存在"
assert_exists "$TEMPLATE/contents/code/main.js" "占位 main.js 存在"
# JSON 可解析且字段精确（python3 断言，值抄 spec 3.2/D9）
python3 - "$TEMPLATE/metadata.json" <<'PY' && pass "占位字段断言" || fail "占位字段断言" "字段不符"
import json, sys
m = json.load(open(sys.argv[1]))
assert m["KPlugin"]["Id"] == "kwin6_effect_bmw_random"
assert m["KPlugin"]["Name"] == "随机特效 [Burn-My-Windows]"
assert m["KPlugin"]["EnabledByDefault"] is False
assert m["X-KWin-Exclusive-Category"] == "toplevel-open-close-animation"
assert m["X-KDE-ConfigModule"] == "kcm_burnwindow"
assert m["X-Plasma-API"] == "javascript"
assert m["KPackageStructure"] == "KWin/Effect"
PY
run node --check "$TEMPLATE/contents/code/main.js"
assert_eq "$RC" "0" "占位 main.js 语法通过 node --check"
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash tests/test_install.sh 2>&1 | head -12`
Expected: `✖ 占位 metadata.json 存在` 等多条 FAIL（模板尚不存在）

- [ ] **Step 3: 创建模板**

`metadata.json`：按 Interfaces 块的字段清单写出（Name/Description/Icon 自拟中文/通用值，Description 示例：`随机播放 Burn-My-Windows 的窗口开/关动画`；`KPlugin.ServiceTypes=["KWin/Effect"]`；`KPlugin.License="GPLv3"`；`X-KDE-Ordering=61`）。

`contents/code/main.js`：空文件（0 字节）。它是纯状态标识，任何 JS 都会与抽中的 winner 产生双重动画风险。

- [ ] **Step 4: 跑测试确认通过**

Run: `bash tests/test_install.sh 2>&1 | grep 'test_placeholder' -A6`
Expected: 静态段全 `✔`（其余用例不受影响）

- [ ] **Step 5: Commit**

```bash
git add placeholder tests/test_install.sh
git commit -m "feat(placeholder): 占位特效模板「随机特效 [Burn-My-Windows]」"
```

---

### Task 3: metadata 双改造（inject.py patch/restore）

**Files:**
- Modify: `lib/inject.py`（新增 `patch_metadata`/`restore_metadata` + CLI 分支）
- Test: `tests/test_inject.py`

**Interfaces:**
- Consumes: Task 2 的字段知识（patch **不作用于**占位：由调用方按 id 过滤，Task 4 负责）
- Produces:
  - `patch_metadata(effect_dir) -> bool`：为 `<effect_dir>/metadata.json` 加 `"X-KWin-Internal": "true"`、把 `X-KWin-Exclusive-Category` 改为 `"bmw-hidden"`；首次修改前把原文件备份为 `metadata.json.orig`；已含 internal 且组名已改 → 不写盘返回 False（幂等）
  - `restore_metadata(effect_dir) -> bool`：存在 `metadata.json.orig` → 还原并删除 `.orig`，返回 True
  - CLI：`python3 inject.py --patch-metadata --effect-dir DIR` 与 `--restore-metadata --effect-dir DIR`（退出码 0/非 0 语义与现有 CLI 一致）—— Task 4/5 消费

- [ ] **Step 1: 写失败测试**

`tests/test_inject.py` 新增 fixture（tmp_path 里放一份仿 fire 的 metadata.json，含 `X-KWin-Exclusive-Category: toplevel-open-close-animation`、无 internal）与 5 条用例：

1. `test_patch_adds_internal_and_changes_category`：patch 后 `X-KWin-Internal == "true"` 且组名 `== "bmw-hidden"`，且 `json.load` 可解析
2. `test_patch_creates_orig_backup`：patch 后 `metadata.json.orig` 内容与原文件字节相同
3. `test_patch_idempotent`：连续 patch 两次，第二次返回 False 且文件字节不变
4. `test_restore_reverts_and_removes_orig`：patch → restore 后 JSON 与原文语义相同、`.orig` 不存在
5. `test_cli_patch_metadata`：`subprocess` 跑 `--patch-metadata --effect-dir ...` 退出码 0 且字段生效（`--restore-metadata` 同）

- [ ] **Step 2: 跑测试确认失败**

Run: `python3 -m pytest tests/test_inject.py -q`
Expected: 5 条 FAIL（AttributeError: patch_metadata / CLI 未知参数）

- [ ] **Step 3: 实现**

`lib/inject.py`：
- `patch_metadata(effect_dir)`：读 JSON → 判断是否需改（缺 internal 或组名非 `bmw-hidden`）→ 需改则先 `shutil.copy2(metadata.json, metadata.json.orig)`（仅当 `.orig` 不存在时备份，保留首改原文）→ 写回（`json.dumps(indent=2, ensure_ascii=False)`）→ 返回是否改动
- `restore_metadata(effect_dir)`：`.orig` 存在 → `move` 覆盖回 `metadata.json` 并删 `.orig` → 返回 True
- `main(argv)` 加两个互斥分支（与现有 `--effect-dir` 参数复用），错误语义走既有 `_die`

- [ ] **Step 4: 跑测试确认通过**

Run: `python3 -m pytest tests/test_inject.py -q`
Expected: 全部 passed（原 7 条 + 新 5 条）

- [ ] **Step 5: Commit**

```bash
git add lib/inject.py tests/test_inject.py
git commit -m "feat(inject): metadata 双改造 patch/restore（internal + 改组名 + .orig 备份，幂等）"
```

---

### Task 4: install.sh 集成

**Files:**
- Modify: `install.sh`（常量、`do_placeholder`、`do_metadata_patch`、`do_inject` 跳过、`emit_apply_script` 跳过、`do_sudo_kcm` 落点+旧落点清理、`print_plan`、`main` 顺序）
- Test: `tests/test_install.sh`

**Interfaces:**
- Consumes: Task 2 模板目录、Task 3 CLI、既有 `POOL_IDS`/`extract_id`
- Produces:
  - 常量 `PLACEHOLDER_ID="kwin6_effect_bmw_random"`（head 段）；`KCM_DEST="/usr/lib/qt6/plugins/kwin/effects/configs/kcm_burnwindow.so"`（替换原 systemsettings 值）
  - `main` 新顺序：`do_build → extract_pool → do_placeholder → do_inject → do_metadata_patch → do_kwinrc → do_apply_script → do_sudo_kcm → do_write_config`
  - `do_inject` 与 `emit_apply_script` 内循环均跳过 `id == PLACEHOLDER_ID`
  - `do_sudo_kcm`：装新落点前若旧落点 `/usr/lib/qt6/plugins/plasma/kcms/systemsettings/kcm_burnwindow.so` 存在则删除（同一提权上下文）
  - 测试隔离：`--prefix` 模式下 `PLACEHOLDER` 目标 = `$PREFIX/effects/$PLACEHOLDER_ID`

- [ ] **Step 1: 写失败测试**

`tests/test_install.sh` 新增用例（沿用 `setup/run/assert_*` 工具，跑 `install.sh --prefix "$PREFIX" --skip-build --skip-kwinrc`）：

1. `test_placeholder_installed`：安装后 `$PREFIX/effects/kwin6_effect_bmw_random/metadata.json` 存在且字段与模板一致（python3 复检 Id/Name）；占位 `contents/code/main.js` **不含** `BMW_ARBITER` 标记
2. `test_metadata_patched_19`：对 `$PREFIX/effects` 下除占位外的每个目录断言 `X-KWin-Internal=="true"`、组名 `=="bmw-hidden"`、`metadata.json.orig` 存在
3. `test_install_idempotent`：连续第二次安装 → 仍只有一份 `.orig`（内容为上游原文）、internal 不重复（json 里是字符串 `"true"` 单键）
4. `test_apply_skips_placeholder`：跑 `install.sh --prefix ... --apply-config` → 退出码 0、输出含 `完成`（占位混入遍历会 `_die`，此用例即 Review Focus #1 的裁判）
5. `test_kcm_dest_new_path`：`grep` 断言 `install.sh` 含 `KCM_DEST="/usr/lib/qt6/plugins/kwin/effects/configs/kcm_burnwindow.so"` 且**不含** `plasma/kcms/systemsettings/kcm_burnwindow.so` 作为 KCM_DEST 赋值；`--dry-run` 计划输出含 `kwin/effects/configs`
6. `test_old_kcm_dest_cleanup`：静态断言 `do_sudo_kcm` 函数体含旧落点路径字符串（清理逻辑存在；真实 sudo 删除由 test_kcm_build 的系统用例覆盖）

- [ ] **Step 2: 跑测试确认失败**

Run: `bash tests/test_install.sh 2>&1 | grep -E '✖' | head`
Expected: 上述用例 FAIL（占位未装、未 patch、KCM_DEST 仍旧值）

- [ ] **Step 3: 实现**

- head 段：加 `PLACEHOLDER_ID`、改 `KCM_DEST`
- 新函数 `do_placeholder`：`[ -d "$EFFECTS_DIR/$PLACEHOLDER_ID" ] || cp -r "$ROOT/placeholder/kwin6_effect_bmw_random" "$EFFECTS_DIR/"`（幂等）；`--prefix` 时 EFFECTS_DIR 已被 prefix 重定向，无需分支
- `do_inject` 循环开头：`[ "$id" = "$PLACEHOLDER_ID" ] && continue`（注入数校验逻辑不变 —— 占位不计入 count）
- 新函数 `do_metadata_patch`：遍历 `POOL_IDS`（不遍历目录，天然排除占位），逐个 `python3 "$INJECT_PY" --patch-metadata --effect-dir "$EFFECTS_DIR/$id"`，任一失败 `die`
- `emit_apply_script` heredoc 内循环：同样加占位跳过（`if [ "$id" = "$PLACEHOLDER_ID" ]; then continue; fi`，注意 heredoc 转义 `\$`）
- `do_sudo_kcm`：install 新路径前，若 `[ -e 旧路径 ]` 则同凭据通道 `rm -f` 旧路径（沿用 SUDO_PASSWORD/缓存两分支写法）
- `print_plan`：步骤文案反映占位写入 + patch + 新 KCM 路径
- `main`：按 Interfaces 顺序插入两步

- [ ] **Step 4: 跑测试确认通过**

Run: `bash tests/test_install.sh 2>&1 | tail -3`
Expected: `结果: PASS=39+N FAIL=0`（N=本次新增用例数）

- [ ] **Step 5: 回归相邻套件 + Commit**

Run: `python3 -m pytest tests/test_inject.py -q && bash tests/test_apply_config.sh 2>&1 | tail -2`
Expected: 全绿（apply 脚本 heredoc 改动的回归）

```bash
git add install.sh tests/test_install.sh
git commit -m "feat(install): 占位写入 + metadata 双 patch + KCM 新落点（旧落点清理）+ 遍历跳过占位"
```

---

### Task 5: uninstall.sh 对称清理

**Files:**
- Modify: `uninstall.sh`（kwinrc 条目步骤、还原注入步骤、特效目录步骤、KCM 步骤、统计输出）
- Test: `tests/test_uninstall.sh`

**Interfaces:**
- Consumes: Task 3 `--restore-metadata` CLI、Task 4 的 `PLACEHOLDER_ID`/新旧 KCM 路径
- Produces: 卸载终态 = 19 个 metadata 还原且 `.orig` 删除、占位目录删除、`[Plugins] kwin6_effect_bmw_randomEnabled` 删除、KCM 新旧两落点均删除。占位键/占位目录**不在 Pool 内**，必须显式处理（spec C5）。

- [ ] **Step 1: 写失败测试**

`tests/test_uninstall.sh` 新增用例（先 install 到 prefix 再 uninstall，沿用现有 fixture 流程）：

1. `test_metadata_restored_on_uninstall`：卸载后 19 个 `metadata.json` 无 `X-KWin-Internal`、组名仍为 `toplevel-open-close-animation`、`metadata.json.orig` 不存在
2. `test_placeholder_removed`：占位目录不存在
3. `test_placeholder_kwinrc_entry_removed`：卸载前预置 `kwriteconfig6 ... --key kwin6_effect_bmw_randomEnabled true`，卸载后 `kreadconfig6` 读该键为空
4. `test_kcm_both_dest_removed`：prefix 模式下新落点与旧落点路径的 KCM 文件均不存在（若 install 未装 KCM 则本条对两路径断言 not exists 的前提态）；静态断言 uninstall.sh 同时含新旧两路径字符串
5. 既有幂等用例保持通过（二次卸载不报错）

- [ ] **Step 2: 跑测试确认失败**

Run: `bash tests/test_uninstall.sh 2>&1 | grep '✖' | head`
Expected: 新用例 FAIL（metadata 未还原、占位残留、占位键残留）

- [ ] **Step 3: 实现**

- 步骤 2（kwinrc 条目清理）：`POOL_IDS` 循环之后补 `[Plugins] kwin6_effect_bmw_randomEnabled` 的 `--delete`（`kwriteconfig6 --file "$KWINRC" --group Plugins --key kwin6_effect_bmw_randomEnabled --delete`；与既有删除写法一致）
- 步骤 3（还原注入）：每成员还原 main.js 后追加 `python3 .../inject.py --restore-metadata --effect-dir "$EFFECTS_DIR/$id"`（inject.py 副本路径复用步骤 3 已解析的变量；源码目录场景用 `$ROOT/lib/inject.py`）
- 步骤 9（特效目录）：POOL 循环之后单独删占位目录（**必须复用同一 id 安全闸 case 模式**：含 `/`、`.`、`..`、`-` 开头拒绝 —— 占位 id 是常量仍走闸，保持一致）
- 步骤 8（KCM）：把单路径逻辑改为对**新旧两条路径**各执行一遍（状态汇总 KCM_STATE 规则不变）
- 统计日志行补占位清理计数

- [ ] **Step 4: 跑测试确认通过**

Run: `bash tests/test_uninstall.sh 2>&1 | tail -3`
Expected: `结果: PASS=29+N FAIL=0`

- [ ] **Step 5: 回归相邻套件 + Commit**

Run: `bash tests/test_install.sh 2>&1 | tail -2`
Expected: 全绿

```bash
git add uninstall.sh tests/test_uninstall.sh
git commit -m "feat(uninstall): metadata 还原 + 占位（目录/键）+ KCM 两落点对称清理"
```

---

### Task 6: KCM C++ 聚合模型

**Files:**
- Modify: `kcm/kcm.h`（属性/方法声明）
- Modify: `kcm/kcm.cpp`（main.xml 解析、开关状态查询、参与映射、参数值读取）
- Test: `tests/test_kcm_build.sh`

**Interfaces:**
- Consumes: `EFFECTS_DIR` 下 19 份 `contents/config/main.xml`（实测格式：`<kcfg><group name=""><entry name="X" type="UInt|Double|Bool|Color"><default>…</default></entry>`，**全池无 min/max/choices**）；kwinrc `[Effect-<id>]` 参数组；D-Bus `org.kde.KWin /Effects loadedEffects`
- Produces（Task 7/8 消费）:
  - `Q_PROPERTY(QVariantList pool …)` 结构扩展为 `[{effectId: string, displayName: string, participating: bool, params: [{name, type, default, value}]}]`（type 取值仅 `UInt|Double|Bool|Color`，value 为当前 kwinrc 值、缺失时回落 default，均为字符串）
  - `Q_PROPERTY(bool randomLoaded READ … NOTIFY randomLoadedChanged)` —— 占位 ∈ loadedEffects
  - `Q_INVOKABLE void toggleParticipating(const QString &effectId, bool participating)`：`participating=true` → 从 `m_blacklist` 移除；false → 加入（即 `Blacklist = 未勾选集合`，D3 反转在 C++ 语义层完成）
  - `Q_INVOKABLE void setParam(const QString &effectId, const QString &name, const QString &value)`：只改内存 `m_paramDirty`（`[{effectId,name,value}]`）并 `setNeedsSave(true)`，**落盘在 Task 8 的 apply()**
  - 诊断输出（测试裁判）：`BMW_KCM_POOL_MODEL=<json>`、`BMW_KCM_RANDOM_LOADED=<true|false>`（经既有 `BMW_KCM_DIAG_*` 模式追加）

- [ ] **Step 1: 写失败测试**

`tests/test_kcm_build.sh` 新增用例（用 `BURN_WINDOW_EFFECTS` 指向 prefix fixture 特效目录 + `BMW_KCM_DIAG_*` 环境跑构建产物，沿用现有诊断断言工具）：

1. `test_pool_model_contains_participating_and_params`：诊断输出 `BMW_KCM_POOL_MODEL=` 的 JSON 中，fire 成员 `participating==true`（blacklist 空）、`params` 含 `{"name":"Duration","type":"UInt","default":"1500"}`；glitch 含 `{"name":"Strength","type":"Double"}`
2. `test_random_loaded_reported`：输出含 `BMW_KCM_RANDOM_LOADED=true|false`（当前环境实测值二选一，先断言键存在 + 值域）
3. `test_toggle_participating_maps_to_blacklist`：调 `toggleParticipating("kwin6_effect_fire", false)` 后（经诊断读回 blacklist）`kwin6_effect_fire` ∈ blacklist；再 `true` → 移出
4. `test_broken_main_xml_skipped_not_fatal`：fixture 里给某成员写坏 `main.xml`（截断 XML）→ KCM 构造不崩溃、该成员 `params==[]`、其余成员正常（stderr 含解析警告）
5. `test_set_param_marks_needs_save`：`setParam` 后 `BMW_KCM_DIAG_APPLY_NEEDSSAVE` 路径外的独立诊断行 `BMW_KCM_PARAMS_DIRTY=1`（新增探针）

- [ ] **Step 2: 跑测试确认失败**

Run: `env SUDO_PASSWORD=1 bash tests/test_kcm_build.sh 2>&1 | grep '✖' | head`
Expected: 新用例 FAIL（诊断键不存在 / 结构缺字段）

- [ ] **Step 3: 实现**

`kcm.h`：新增上述 Q_PROPERTY/Q_INVOKABLE 声明与成员 `QVariantList m_paramsDirty`、`bool m_randomLoaded`；`toggleBlacklist` 保留（内部映射工具），语义入口以 `toggleParticipating` 为准。

`kcm.cpp`：
- `parseMainXml(effectId) -> QVariantList`：`QXmlStreamReader`（QtCore 自带，无需新依赖）解析 `<entry>` 的 `name/type/default`；XML 病态 → warn 到 stderr 返回空表（Review Focus #2 相邻：解析失败不致命）
- `loadConfig()` 扩展：每池成员拼 `params`（值 = `KConfig kwinrc` 的 `Effect-<id>` 组 `readEntry(name, default)`）+ `participating = !m_blacklist.contains(id)`；查询 `randomLoaded`：`QProcess` 同步 `qdbus6 org.kde.KWin /Effects org.kde.kwin.Effects.loadedEffects`（与 apply 同模式，不加 CMake 依赖），输出 split `,` 是否含 `PLACEHOLDER_ID`（`kwin6_effect_bmw_random` 硬编码常量与 inject 一致）
- 诊断构造尾部输出 `BMW_KCM_POOL_MODEL` / `BMW_KCM_RANDOM_LOADED` / `BMW_KCM_PARAMS_DIRTY`
- `setParam`：upsert 进 `m_paramDirty`，`setNeedsSave(true)` + emit（供 Task 7 绑定）

- [ ] **Step 4: 跑测试确认通过**

Run: `env SUDO_PASSWORD=1 bash tests/test_kcm_build.sh 2>&1 | tail -3`
Expected: `结果: PASS=15+N FAIL=0`

- [ ] **Step 5: Commit**

```bash
git add kcm/kcm.h kcm/kcm.cpp tests/test_kcm_build.sh
git commit -m "feat(kcm): 聚合模型 —— main.xml 参数解析 + 参与语义 + 开关只读状态"
```

---

### Task 7: KCM QML 聚合页

**Files:**
- Modify: `kcm/ui/main.qml`
- Test: `tests/test_kcm_qml.sh`

**Interfaces:**
- Consumes: Task 6 的 `kcm.pool`（含 participating/params）、`kcm.randomLoaded`、`kcm.toggleParticipating`、`kcm.setParam`
- Produces: 页面结构（spec 4.3）—— 顶部说明（勾上=参与）+ 开关只读徽标 + 19 项 Repeater（CheckBox 参与 + 「参数 ▸」展开 + 按 type 动态控件）。控件映射：`UInt → SpinBox [0,65535]`、`Double → SpinBox [0,1000] decimals=2 stepSize=0.01`、`Bool → CheckBox`、`Color → ColorButton`（首选 `import org.kde.kquickcontrolsaddons`；若 QML 加载测试失败则降级 `QQC2.TextField` + `#RRGGBB` 文本，以 test_kcm_qml 为裁判）。边界值依据：全池实测 Duration 最大 1500、Double 实测 0.5–2，65535/1000 为覆盖余量（spec 未钉值 → 本计划钉值）。

- [ ] **Step 1: 写失败测试**

`tests/test_kcm_qml.sh` 新增断言（沿用现有 QML 加载 + journal 探针工具）：

1. `test_participating_default_all_checked`：诊断（blacklist 空）下探针 `BMW_KCM_PARTICIPATING <id>=true` 对 19 个 id 全部成立 —— **勾上=参与**（反转后的新默认）
2. `test_switch_badge_rendered`：探针 `BMW_KCM_SWITCH_BADGE=已启用|未启用` 存在（`randomLoaded` 只读展示，**页面不得出现任何 toggle 开关**：静态断言 main.qml 无 `kcm.setRandomLoaded`/开关类调用 —— D6）
3. `test_param_widgets_rendered`：探针 `BMW_KCM_PARAM_WIDGET <effectId> <name> <type>` 对 fire 的 `Duration UInt`、glitch 的 `Strength Double` 至少各一行
4. `test_param_control_wiring`：探针 `BMW_KCM_PARAM_EDIT <effectId> <name>=<value>` 初始值等于 kwinrc 现值（或 default）

- [ ] **Step 2: 跑测试确认失败**

Run: `env SUDO_PASSWORD=1 bash tests/test_kcm_qml.sh 2>&1 | grep '✖' | head`
Expected: FAIL（新探针不存在；现有 `BMW_KCM_ITEM` 探针语义也将随反转失效 → 同步改现有断言为 `checked=true` 表示参与）

- [ ] **Step 3: 实现**

`main.qml` 重构：
- 顶部 Label 文案改：`勾选的特效参与窗口打开与关闭的随机选择；取消勾选则剔除。默认全部勾选。`
- 徽标 Label：`text: kcm.randomLoaded ? "随机特效：已启用" : "随机特效：未启用"`（只读，非开关）
- Repeater 委托改双行结构：`QQC2.CheckBox { checked: modelData.participating; onClicked: kcm.toggleParticipating(modelData.effectId, checked) }` + `QQC2.Button { text: "参数 ▸"; onClicked: paramsBox.visible = !paramsBox.visible }` + `ColumnLayout`（`visible: false` 初始）内 Repeater `modelData.params` 按 `type` 分支控件，`onValueModified/onToggled/onTextEdited` → `kcm.setParam(modelData.effectId, name, 值字符串)`
- 探针：`Component.onCompleted` 输出 `BMW_KCM_PARTICIPATING`/`BMW_KCM_SWITCH_BADGE`/`BMW_KCM_PARAM_WIDGET`/`BMW_KCM_PARAM_EDIT`（沿用现有 console.log → journal 断言模式）
- 保留 `BMW_KCM_QML_LOADED` 等既有探针与 applyOutput 展示

- [ ] **Step 4: 跑测试确认通过**

Run: `env SUDO_PASSWORD=1 bash tests/test_kcm_qml.sh 2>&1 | tail -3`
Expected: `结果: PASS=13+N FAIL=0`（含既有反转同步断言）

- [ ] **Step 5: Commit**

```bash
git add kcm/ui/main.qml tests/test_kcm_qml.sh
git commit -m "feat(kcm-ui): 聚合页 —— 勾上=参与 + 开关只读徽标 + 类型化参数面板"
```

---

### Task 8: save 链路（参数落盘 + reconfigureEffect）

**Files:**
- Modify: `kcm/kcm.cpp`（`apply()` 扩展参数段）
- Test: `tests/test_kcm_build.sh`

**Interfaces:**
- Consumes: Task 6 的 `m_paramDirty`、`finishApply`/15s 超时契约（既有）
- Produces: `apply()` 新序 —— `saveBlacklist()` → **参数段** → 既有 apply 子进程；参数段 = 对 `m_paramDirty` 逐条 `KConfig kwinrc` `KConfigGroup("Effect-<id>").writeEntry(name, value)` + `group.sync()`，对**去重后的 effectId** 各调一次 `QProcess::execute("qdbus6", {"org.kde.KWin","/Effects","reconfigureEffect", id})`；失败仅 append 警告到 `m_applyOutput`、不置 `finishApply(false)`（参数已落盘，spec 5.1）。诊断：`BMW_KCM_PARAM_WRITE=<id>:<name>:<value>`、`BMW_KCM_RECONFIGURE=<id>`。

- [ ] **Step 1: 写失败测试**

`tests/test_kcm_build.sh` 新增（prefix 隔离 kwinrc：`BURN_WINDOW_CONFIG` 同款机制给 kwinrc 用临时文件 —— 环境变量 `BMW_KCM_KWINRC`（新，实现时同向注入到 KConfig 打开路径；若沿用真实 kwinrc 则测试仅断言诊断行不改真值，优先临时文件））：

1. `test_param_write_hits_effect_group`：`setParam("kwin6_effect_fire","Duration","999")` → 诊断 `BMW_KCM_PARAM_WRITE=kwin6_effect_fire:Duration:999`，且 `kreadconfig6 --file <tmp kwinrc> --group Effect-kwin6_effect_fire --key Duration == 999`
2. `test_reconfigure_called_per_effect`：两条 param 同 id + 一条异 id → `BMW_KCM_RECONFIGURE` 行数 == 去重 id 数
3. `test_reconfigure_failure_keeps_apply_ok`：`qdbus6` 不可用（PATH 注入假 qdbus6 退出 1）→ apply 仍 exit 0、`BMW_KCM_DIAG_APPLY_OUTPUT` 含警告文本、`BMW_KCM_DIAG_APPLY_RUNNING=false`
4. 既有 15s 超时/失败路径用例保持全绿

- [ ] **Step 2: 跑测试确认失败**

Run: `env SUDO_PASSWORD=1 bash tests/test_kcm_build.sh 2>&1 | grep '✖' | head`
Expected: FAIL（诊断行不存在、tmp kwinrc 无键）

- [ ] **Step 3: 实现**

`kcm.cpp`：
- `loadConfig` 处理新环境变量 `BMW_KCM_KWINRC`（空则 `~/.config/kwinrc`）→ 参数读写都用该路径（KConfig 构造复用）
- `apply()` 在 `saveBlacklist()` 之后插入参数段（循环写入 + 收集去重 id + 逐 id `QProcess::execute` + 诊断行），然后照旧启动 apply 子进程
- `m_paramDirty` 成功写入后清空；`finishApply(false)` 路径不清（用户可重试）

- [ ] **Step 4: 跑测试确认通过 + 全量 KCM 套件**

Run: `env SUDO_PASSWORD=1 bash tests/test_kcm_build.sh 2>&1 | tail -3 && env SUDO_PASSWORD=1 bash tests/test_kcm_qml.sh 2>&1 | tail -3`
Expected: 两套全绿

- [ ] **Step 5: Commit**

```bash
git add kcm/kcm.cpp tests/test_kcm_build.sh
git commit -m "feat(kcm): save 参数段 —— kwinrc [Effect-*] 落盘 + reconfigureEffect 生效"
```

---

### Task 9: e2e 开关链路

**Files:**
- Modify: `tests/test_e2e.sh`（前置、trap、新用例）
- Test: `tests/test_e2e.sh` 自身

**Interfaces:**
- Consumes: Task 1 的开关闸（运行时行为）、KConfig Notify 链（`kwriteconfig6 --notify` 写 `[Plugins]` 键 → KWin 自动 load/unload 占位）
- Produces: e2e 前置新增「开启占位」（否则 19 个 isEffectLoaded=false → 全部不播，现有 1-4 用例会假失败）；trap 新增 `restore_random_switch`；新用例 `test_random_switch_gates_playback`。

- [ ] **Step 1: 写失败测试（新用例先落文件）**

`tests/test_e2e.sh`：

- 前置（`echo "=== 前置检查 ==="` 段内、LOADED_N 检查之前）加：

> ⚠️ 必须同时修既有断言：`loaded_bmw` 按 `kwin6_effect_` 前缀提取，占位 id `kwin6_effect_bmw_random` 以同前缀计入 → `LOADED_N==19` 会变 20 假失败。改法：`loaded_bmw` 的 grep 行加 `grep -v '^kwin6_effect_bmw_random$'` 排除占位（池成员计数语义不变），或 LOADED_N 断言改按 `POOL` 清单逐个核对。

```bash
PLACEHOLDER_ID="kwin6_effect_bmw_random"
random_switch() {  # random_switch on|off —— 写占位键并等 KWin 生效
  if [ "$1" = on ]; then
    kwriteconfig6 --notify --file "$KWINRC" --group Plugins --key "${PLACEHOLDER_ID}Enabled" true
  else
    kwriteconfig6 --notify --file "$KWINRC" --group Plugins --key "${PLACEHOLDER_ID}Enabled" false
  fi
  local want="$1" i
  for i in $(seq 1 50); do
    local loaded; loaded="$(loaded_all)"
    if { [ "$want" = on ] && echo "$loaded" | grep -q "^${PLACEHOLDER_ID}$"; } || \
       { [ "$want" = off ] && ! echo "$loaded" | grep -q "^${PLACEHOLDER_ID}$"; }; then return 0; fi
    sleep 0.2
  done
  return 1
}
restore_random_switch() { random_switch off >/dev/null 2>&1 || true; }
trap 'restore_blacklist; restore_random_switch; rm -rf "$TMP"' EXIT
random_switch on || echo "  警告：占位开启未生效（KWin 可能未运行），开关用例将失败"
```

（`loaded_all` = 已有 `loaded_bmw` 同风格的全量 loadedEffects 提取函数，若已有类似工具直接复用）

- 新用例（放 role 冲突用例之后）：

```bash
echo "=== test_random_switch_gates_playback ==="
if [ "$INSTALLED" -eq 1 ]; then
  assert_true "random_switch on" "开态：占位进入 loadedEffects"
  run_rounds t_on 10
  assert_true "[ -n \"$(collect_all t_on)\" ]" "开态：19 个特效产生动画"
  assert_true "random_switch off" "关态：占位离开 loadedEffects"
  run_rounds t_off 10
  assert_eq "$(collect_all t_off | grep -c '^kwin6_effect_' || true)" "0" "关态：无任何 kwin6_effect_* 动画"
  assert_true "random_switch on" "重开：占位回到 loadedEffects"
  run_rounds t_re 10
  assert_true "[ -n \"$(collect_all t_re)\" ]" "重开：随机播放恢复"
else
  echo "  ✖ 未安装，跳过开关用例" ; FAIL=$((FAIL+1))
fi
```

- [ ] **Step 2: 跑测试确认失败（RED）**

Run: `bash tests/test_e2e.sh 2>&1 | tail -5`（**单独串行**）
Expected: `test_random_switch_gates_playback` FAIL（当前无占位、无开关逻辑）—— 这是 Task 1/2/4 已实现后的集成 RED；若此前任务未完成则前置即失败，按依赖顺序执行本任务即无此问题

- [ ] **Step 3: 实现运行时接线核验（若 Step 2 全绿则本步只记录）**

开关链路的运行时实现已在 Task 1（仲裁闸）+ Task 4（占位安装）完成；本任务只补 e2e 装配。若关态断言失败 → 检查注入产物 `effects.isEffectLoaded(BMW_PLACEHOLDER_ID)` 是否真实生效（journal 查 `BMW_ROLE` 行）再定位。

- [ ] **Step 4: 跑测试确认通过**

Run: `bash tests/test_e2e.sh 2>&1 | grep '结果:'`
Expected: `结果: PASS=14+N FAIL=0`（N ≥ 5）

- [ ] **Step 5: Commit**

```bash
git add tests/test_e2e.sh
git commit -m "test(e2e): 开关链路用例 —— 开/关/重开三态随机播放门控"
```

---

### Task 10: 真实环境重装 + 全量回归 + 手动验收

**Files:**
- 无新文件（执行与验收任务）

**Interfaces:**
- Consumes: Task 1–9 全部产物
- Produces: 真实环境终态 + 全量绿的验收记录

- [ ] **Step 1: 真实环境重装**

Run: `env SUDO_PASSWORD=$SUDO_PASSWORD bash install.sh --skip-build`
Expected: 输出「安装完成」；`qdbus6 org.kde.KWin /Effects loadedEffects` 含 19 个池成员（常驻）；`$HOME/.local/share/kwin/effects/kwin6_effect_bmw_random/metadata.json` 存在；`/usr/lib/qt6/plugins/kwin/effects/configs/kcm_burnwindow.so` 存在

- [ ] **Step 2: 开关链路实测（含 V1/V3/V4 待验证项）**

1. `kwriteconfig6 --notify --file ~/.config/kwinrc --group Plugins --key kwin6_effect_bmw_randomEnabled true` → 断言占位 ∈ loadedEffects（**V1 空 main.js 加载**，同步看 `journalctl --user`/`journal -b` 无加载错误）
2. 手动开/关窗口 → 观察随机动画（journal 中 BMW_ROLE 行）
3. 写 false + notify → 占位 unloaded → 开关窗口无动画
4. **系统设置 → 外观 → 动效**：下拉仅见「随机特效 [Burn-My-Windows]」+ 内置项（19 个不出现）；桌面特效列表无 19 个（internal 生效）
5. 点行尾齿轮 → 聚合页打开（**V3 KCM 落点 / V4 ConfigurableRole**）；19 项全勾、参数面板渲染、改 Duration 保存后 kwinrc 读回 + 动画时长变化
6. 旧入口「窗口管理 → Burn Window」不存在（D8）

- [ ] **Step 3: 全量 8 套回归**

Run（严格按序，e2e 最后单独）:

```bash
node --test tests/arbiter.test.mjs
python3 -m pytest tests/test_inject.py -q
bash tests/test_install.sh
bash tests/test_apply_config.sh
env SUDO_PASSWORD=1 bash tests/test_kcm_build.sh
env SUDO_PASSWORD=1 bash tests/test_kcm_qml.sh
bash tests/test_uninstall.sh
bash tests/test_e2e.sh   # 单独串行
```

Expected: 8/8 全绿（各套结果行 PASS=N FAIL=0）

- [ ] **Step 4: 卸载回环验证（可选但推荐）**

Run: `env SUDO_PASSWORD=$SUDO_PASSWORD bash uninstall.sh && bash install.sh --skip-build --skip-sudo`
Expected: 卸载后占位/`.orig`/占位键/新落点 KCM 全部清除、19 个 metadata 还原；重装后状态恢复 —— 证明 C4/C5 对称

- [ ] **Step 5: 验收报告 + Commit（若验收产生文档）**

记录 Step 1–4 输出到 `docs/superpowers/plans/` 同名验收段或 ledger，`git commit -m "docs: 聚合入口真实环境验收记录"`。

---

## Self-Review 记录（计划完成后执行）

1. **Spec coverage**：§1.1 目标 → Task 4/7/9/10；D1–D9 → Task 2（D9）/4（D1 入口装配）/7（D2/D3/D6）/9（D4/D5）/4+5（D8）/6+7（D7）；§3.2 占位 → Task 2/4；§3.3 双改造 → Task 3/4/5；§3.4 三数据流 → Task 1（开关）/4+5（勾选 apply 链路沿用）/8（参数）；§4.1 落点 → Task 4/5；§4.2/4.3 → Task 6/7/8；§4.4 → Task 1；§5.1 错误处理 → Task 6（坏 XML）/8（reconfigure 失败）/4（KCM 未装既有行为）；§5.2 测试 → 各任务 Step 1；§7.1 V1/V3/V4 → Task 10 Step 2。
2. **Step scan**：每步一个可检查动作；实现步只给签名/常量/序，不写函数体转录。
3. **Type consistency**：`bmwShouldPlay` 第 7 参在 Task 1 定义、inject.py 同任务改调用行；`pool` 结构 Task 6 定义 → Task 7 消费；`m_paramDirty` Task 6 定义 → Task 8 消费；`PLACEHOLDER_ID` Task 4 定义 → Task 5 消费。
4. **Review Focus**：5 项均已挂测试（见各任务 Step 1 对应用例）。
5. **Proportion**：计划 ~470 行 vs spec ~320 行；代码块仅为测试断言（spec 值）与关键算法（无），未超纲。
