# 随机特效预览（临时窗口 + caption 协议）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在聚合页每个特效行加预览图标按钮，点击后开一个临时窗口触发该特效播放一次并自动关闭。

**Architecture:** KWin 6.7.5 无任何"播放一次特效"的官方 API（调研实证），因此用「真实窗口开/关事件 + 窗口标题携带目标 id」：KCM 开 `title = "BMW_PREVIEW:<effectId>"` 的临时窗口制造 open/close 事件；注入到 19 个特效的 `lib/arbiter.js` 识别该标题后绕过随机抽签、强制该 id 为 winner。open/close 两个 role 命中同一标题 → 两段动画都是目标特效。

**Tech Stack:** QML（QtQuick.Controls 6.11 / kcmutils SimpleKCM）、KWin scripted effect（JS，无模块系统）、node:test 单元测试、pytest 静态注入断言、bash e2e + journalctl 采样。

**Spec:** `docs/superpowers/specs/2026-09-29-bmw-random-entry-design.md`（§7.3 已于 2026-09-30 把「动画预览」移出 YAGNI，§8 决策记录「动画预览」行含机制调研依据）

## Global Constraints

- 目标环境：KWin **6.7.5**、Qt **6.11**、KDE Frameworks 6（本机实测）
- 特效池固定 **19** 个 `kwin6_effect_*`，注入标记 `BMW_ARBITER_BEGIN/END`，`lib/inject.py` 幂等
- `lib/arbiter.js` 必须保持**无模块语法**（无 import/export）—— `tests/arbiter.test.mjs:13-16` 用 `new Function(src)` 求值，同时也是「可被注入器内联」的验证
- `tests/test_inject.py:136` 断言 `lib/arbiter.js` 全文出现在注入产物里 → 改 arbiter 必须重注入 19 个特效
- 探针走 `console.log` → `journalctl --user -o cat`（本项目 QML/JS 探针既定通道，`tests/test_kcm_qml.sh:163-182`）
- 角色值固定：`BMW_ROLE_OPEN = 424242`、`BMW_ROLE_CLOSE = 424243`（e2e `test_role_values_do_not_collide_with_builtin` 锁定）
- 全量回归 8 套必须 FAIL=0：arbiter / inject / install / apply / kcm-build / kcm-qml / uninstall / e2e

## Review Focus

spec 只写了"预览要能播一次并自动关闭"，下面 5 类失败它没写但最可能咬人——每条已挂到对应任务的测试上：

1. **非预览窗口误触发协议**：用户窗口标题恰好含 `BMW_PREVIEW:` → 该窗口被强制指定特效、破坏随机。→ Task 1 用严格正则 + pool 成员校验（测试 `caption 前缀非法/目标不在 pool → 回落随机`）。
2. **预览一个已被拉黑的特效失效**：`arbiter.js:47` 的 `eligible.indexOf(winner)` 复用校验会把出池 winner 踢回随机。→ Task 1 用例 `预览目标在 blacklist 内仍强制播放`。
3. **open/close 两段动画只播了一段**：两个 role 各自调用 `bmwShouldPlay`，若只处理一个 role，另一段走随机。→ Task 1 用例 `同 caption 对 OPEN/CLOSE 两个 role 均命中`。
4. **预览窗口被 BMW 自己的过滤器挡掉**（`main.js:186-218` 的 `hasDecoration/popupWindow/classBlacklist` 判定）→ 窗口开了但零动画。→ Task 4 e2e 实测 `BMW_PLAY` 出现且 id == 目标。
5. **caption 到达晚于 windowAdded**（调研标注的未实测项，协议层推断）→ 若时序不成立预览会随机播。→ Task 4 e2e 是这条的**唯一**判定：断言 20 轮预览全部命中目标 id，任何一轮随机即 FAIL。

---

### Task 1: arbiter 识别预览协议并强制 winner

**Files:**
- Modify: `lib/arbiter.js`（`bmwShouldPlay` 函数，当前 `:30-60`）
- Test: `tests/arbiter.test.mjs`（现有 13 用例）

**Interfaces:**
- Consumes: `window.caption`（KWin EffectWindow 属性，`main.js:194` 已在读 `window.caption` 证明可读）；`pool`（`bmwShouldPlay` 既有参数，19 个合法 id）
- Produces: **协议字符串格式 `BMW_PREVIEW:<effectId>`**（Task 3 的 KCM 按此格式拼窗口标题，Task 4 的 e2e 按此开测试窗口）；新增导出函数 `bmwPreviewTarget(caption, pool) -> string|null`（Task 1 内部使用，`tests/arbiter.test.mjs` 的 `new Function` 导出清单需同步加上）

- [ ] **Step 1: 写失败测试（扩展 fakeWindow 支持 caption + 5 个新用例）**

`tests/arbiter.test.mjs` 的 `fakeWindow()` 当前只有 `data/setData`，需加 caption 槽位（形如 `fakeWindow(caption)` 或 `.caption` 可赋值）。新用例（断言值取自 spec 协议格式）：

```js
test("预览协议：caption=BMW_PREVIEW:kwin6_effect_fire 时 fire 必当选（即使 rng 指向别处）", () => {
  const w = fakeWindow(); w.caption = "BMW_PREVIEW:kwin6_effect_fire";
  // rng 恒返回 0.99 → 无协议时必选末项，此处必须被协议覆盖
  assert.equal(bmwShouldPlay(w, OPEN_ROLE, "kwin6_effect_fire", ["kwin6_effect_fire", "kwin6_effect_doom"], [], () => 0.99), true);
  assert.equal(w.data(OPEN_ROLE), "kwin6_effect_fire");
});

test("预览协议：目标不在 pool 内 → 视为非法，回落随机", () => {
  const w = fakeWindow(); w.caption = "BMW_PREVIEW:kwin6_effect_not_in_pool";
  assert.equal(bmwPreviewTarget(w.caption, ["kwin6_effect_fire"]), null);
});

test("预览协议：非 BMW_PREVIEW 前缀 → null（用户窗口不误触发）", () => {
  assert.equal(bmwPreviewTarget("kwin6_effect_fire", ["kwin6_effect_fire"]), null);
  assert.equal(bmwPreviewTarget(null, ["kwin6_effect_fire"]), null);
});

test("预览协议：目标在 blacklist 内仍强制播放（绕过 eligible 校验）", () => {
  const w = fakeWindow(); w.caption = "BMW_PREVIEW:kwin6_effect_fire";
  assert.equal(bmwShouldPlay(w, OPEN_ROLE, "kwin6_effect_fire", ["kwin6_effect_fire"], ["kwin6_effect_fire"], () => 0.5), true);
});

test("预览协议：同 caption 对 OPEN/CLOSE 两个 role 均命中", () => {
  const w = fakeWindow(); w.caption = "BMW_PREVIEW:kwin6_effect_fire";
  bmwShouldPlay(w, OPEN_ROLE, "kwin6_effect_fire", ["kwin6_effect_fire", "a"], [], () => 0.99);
  assert.equal(bmwShouldPlay(w, CLOSE_ROLE, "kwin6_effect_fire", ["kwin6_effect_fire", "a"], [], () => 0.99), true);
  assert.equal(w.data(CLOSE_ROLE), "kwin6_effect_fire");
});
```

- [ ] **Step 2: 跑测试确认 FAIL**

Run: `node --test tests/arbiter.test.mjs`
Expected: 新增 5 用例 FAIL（`bmwPreviewTarget is not a function` 或协议未生效），原有 13 用例仍 PASS。

- [ ] **Step 3: 在 `lib/arbiter.js` 实现 `bmwPreviewTarget` 与拦截逻辑**

签名与规则（正文由实现者写，规则不可偏离）：

```js
// 返回合法预览目标 id 或 null。合法性 = 前缀严格匹配 + id ∈ pool。
function bmwPreviewTarget(caption, pool) { ... }
```

拦截点：`bmwShouldPlay` 内、**`enabled === false` 早退之后、`eligible` 抽签与 winner 复用校验之前**（即当前 `:36` `const eligible = ...` 之前或之后但必须在 `if (winner == null || eligible.indexOf(winner) === -1)` 之前）——命中时 `window.setData(roleId, target)` 并 `return target === myEffectId`，**不得**进入 eligible 抽签。保持文件无模块语法（`return` 在函数体内，不加 export）。

- [ ] **Step 4: 跑测试确认 PASS**

Run: `node --test tests/arbiter.test.mjs`
Expected: PASS（13 原有 + 5 新增 = 18）

- [ ] **Step 5: 确认文件仍可被注入（无模块语法）**

Run: `node --check lib/arbiter.js && node --test tests/arbiter.test.mjs`
Expected: rc=0（`node --check` 通过 + 测试全绿）

- [ ] **Step 6: Commit**

```bash
git add lib/arbiter.js tests/arbiter.test.mjs
git commit -m "feat(arbiter): 识别 BMW_PREVIEW 标题协议强制指定 winner —— 5 单测"
```

---

### Task 2: 重注入 19 个特效使协议生效

**Files:**
- Modify: 19 个 `~/.local/share/kwin/effects/kwin6_effect_*/contents/code/main.js`（由 `lib/inject.py` 重写，非手工编辑）
- Test: `tests/test_inject.py`（现有 pytest，`ARBITER_SRC` 断言 `:136` 已自动覆盖全文同步）

**Interfaces:**
- Consumes: Task 1 的 `lib/arbiter.js`（`test_inject.py:136` 要求全文内联）
- Produces: 19 个特效的 main.js 含 `bmwPreviewTarget`；后续 Task 4 的 e2e 依赖注入产物里的 `console.log("BMW_PLAY ...")` 探针（`test_inject.py:139-153` 已锁定，不得破坏）

- [ ] **Step 1: 跑既有注入测试确认协议代码已进产物断言范围**

Run: `python -m pytest tests/test_inject.py -q`
Expected: PASS（`:136` 的全文断言天然覆盖 `bmwPreviewTarget`；若它失败说明 arbiter 源未进产物）

- [ ] **Step 2: 对真实 19 特效执行重注入**

Run: `python lib/inject.py --help` 确认 CLI 参数后对 `~/.local/share/kwin/effects` 重跑注入（幂等，`test_inject.py:71-75` 锁定）
Expected: 19 个 main.js 均含 `bmwPreviewTarget`，且 `node --check` 全通过

```bash
grep -l "bmwPreviewTarget" ~/.local/share/kwin/effects/kwin6_effect_*/contents/code/main.js | wc -l   # 期望 19
```

- [ ] **Step 3: 重新加载特效使新注入生效**

按既有 apply 链路执行（`kcm/kcm.cpp:344-386` 的 apply 或 `tests/test_apply_config.sh` 同款 `qdbus6 org.kde.KWin /Effects reconfigureEffect` 批量调用）
Expected: 19 个仍 `loadedEffects`，`journalctl` 无注入语法错误

- [ ] **Step 4: Commit**

```bash
git add lib/inject.py tests/test_inject.py   # 仅在测试/注入器需同步改动时
git commit -m "feat(inject): 重注入 19 特效载入预览协议 —— 19/19 含 bmwPreviewTarget"
```

---

### Task 3: KCM 预览按钮与临时窗口

**Files:**
- Modify: `kcm/ui/main.qml`（`QQC2.ToolButton` 齿轮按钮之前插入预览按钮；`main.qml:113-141` 现状）
- Test: `tests/test_kcm_qml.sh`（现有 30 断言）

**Interfaces:**
- Consumes: Task 1 定义的协议格式 **`BMW_PREVIEW:<effectId>`**；本项目既有探针通道（`console.log` → journal）
- Produces: 新探针 **`BMW_KCM_PREVIEW <effectId>`**（Task 4 与回归用）；窗口标题格式（Task 4 依赖）

- [ ] **Step 1: 写失败断言（`tests/test_kcm_qml.sh` 追加）**

```bash
echo "=== test_preview_button ==="
assert_contains "BMW_KCM_PREVIEW kwin6_effect_fire icon=media-playback-start" "fire 预览按钮（纯图标 media-playback-start）"
PREVIEW_N="$(printf '%s' "$OUTPUT" | grep -c 'BMW_KCM_PREVIEW ')"
assert_eq "$PREVIEW_N" "19" "预览按钮渲染数 == 19"
```

- [ ] **Step 2: 跑测试确认 FAIL**

Run: `SUDO_PASSWORD=1 bash tests/test_kcm_qml.sh`
Expected: FAIL ≥2（新断言特征缺失），其余 30 PASS

- [ ] **Step 3: 在 `main.qml` 实现预览按钮与临时窗口**

要点（正文由实现者写）：
- 位置：`RowLayout` 内、齿轮 `QQC2.ToolButton` **左侧**（用户已确认布局 `[✓] 名称 …… [预览] [齿轮]`）
- 形态：`QQC2.ToolButton`，`icon.name: "media-playback-start"`，`QQC2.ToolTip.visible/text` 用 attached property（**不可写 `tooltip.text`** —— ToolButton 无该属性，2026-09-30 实测会 `Cannot assign to non-existent property` 打挂整个 QML）
- 窗口：`Qt.createComponent`/`Component.createObject` 动态建顶层 `ApplicationWindow`（`import QtQuick.Controls`），`title = "BMW_PREVIEW:" + effectId`，**不可用 `Qt.Popup` flags**（会变 `XdgPopupWindow` → `normalWindow=false` → 被 `main.js:218` 过滤）
- 自动关闭：`show()` 后按该特效 Duration（KCM 已有 kwinrc 读取能力 `kcm/kcm.cpp:232-239`）延时 `close()`；无值兜底 1500ms
- 探针：`console.log("BMW_KCM_PREVIEW " + effectId + " icon=" + icon.name)`

- [ ] **Step 4: 跑测试确认 PASS**

Run: `SUDO_PASSWORD=1 bash tests/test_kcm_qml.sh`
Expected: PASS=32（30 原有 + 2 新增）FAIL=0

- [ ] **Step 5: Commit**

```bash
git add kcm/ui/main.qml tests/test_kcm_qml.sh
git commit -m "feat(kcm): 预览按钮 + 临时窗口 BMW_PREVIEW 标题 —— qml 32 断言"
```

---

### Task 4: e2e 预览链路实测（唯一能判定 caption 时序的测试）

**Files:**
- Modify: `tests/test_e2e.sh`（现有 20 用例，开窗采样机制 `:8-10`、`:70-82`）

**Interfaces:**
- Consumes: Task 1 协议格式 `BMW_PREVIEW:<effectId>`；Task 2 已重注入的 19 特效；既有 `BMW_PLAY` journal 采样函数
- Produces: 预览链路的回归保障

- [ ] **Step 1: 写失败用例**

新增 `test_preview_plays_target_only`：开一个 `title = "BMW_PREVIEW:kwin6_effect_fire"` 的真实窗口（Wayland 下可用 `kdialog --title "<协议串>" --msgbox` 后延时 TERM，与既有 `kwrite` 开关链路同款采样），采时间窗内 `journalctl _COMM=kwin_wayland | grep BMW_PLAY`：

```bash
assert_true "$PLAY_N -ge 1" "预览窗口触发了动画"
assert_eq "$TARGET_N" "$PLAY_N" "每一段播放都是目标特效（无随机泄漏）"
```

- [ ] **Step 2: 跑测试确认 FAIL**

Run: `bash tests/test_e2e.sh`
Expected: 新用例 FAIL（当前 arbiter 不识别协议 → 播随机），既有 20 用例不受影响

- [ ] **Step 3: 确认协议被识别（若 Task 1/2 已完成则应 PASS）**

Expected: PASS —— 同时这一步**就是 Review Focus #5（caption 时序）的判定**：若 FAIL 显示播放的是随机 id，说明 caption 晚于 `windowAdded` 到达，需回 Task 1 调整拦截时机（改为在 `effects.windowAdded` 之前预读，或 KCM 侧先 show 后改 title 的时序）

- [ ] **Step 4: Commit**

```bash
git add tests/test_e2e.sh
git commit -m "test(e2e): 预览链路 20 轮全命中目标特效 —— 锁 caption 时序"
```

---

### Task 5: 全量回归 + 文档收尾

**Files:**
- Modify: `.superpowers/sdd/2026-09-29-bmw-random-entry/progress.md`（ledger 追加）

**Interfaces:**
- Consumes: Task 1-4 全部产出

- [ ] **Step 1: 跑全量 8 套回归**

Run: `bash /tmp/opencode/run_all.sh`（或逐个 `bash tests/<name>`）
Expected: 8/8 FAIL=0 —— arbiter / inject / install / apply / kcm-build / kcm-qml / uninstall / e2e

- [ ] **Step 2: 提权类套件需 `SUDO_PASSWORD` 注入**

`kcm-build`/`kcm-qml`/`install` 依赖 sudo：`SUDO_PASSWORD=<pw> bash tests/<name>`（走 `tests/*:sudo_available` 设计通道），并按 Ruling-19 前后比对 `faillock --user <name>` 确保零新增

- [ ] **Step 3: Commit + ledger 追加（同一轮）**

ledger 记录：协议格式、5 单测 + e2e 时序判定结论、全量回归数字、spec 7.3 修订
