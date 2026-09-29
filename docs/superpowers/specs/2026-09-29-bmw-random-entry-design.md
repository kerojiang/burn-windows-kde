# 随机特效聚合入口 —— 设计文档

> 日期：2026-09-29　状态：待用户审阅
> 前置文档：`2026-09-29-bmw-random-kwin-design.md`（基础包装层，已实现）
> 本文档的上游机制结论全部来自 KWin v6.7.5 tag 源码逐行核对（与本机 Arch `kwin 6.7.5-1` 严格对应），依据链接见第 6 章与附录 A。

---

## 1. 需求与约束

### 1.1 目标

把「19 个 BMW 特效挤在 KDE 动效下拉里单选、误选一个即破坏随机」的现状，改造为：

1. 系统设置 → 外观 → 动效的「窗口打开/关闭」下拉里**只显示一个「随机特效」条目**；
2. 该条目行尾的**齿轮按钮**打开**聚合配置页**，页内可对 19 个特效逐项勾选与调参；
3. **下拉就是唯一总开关**，遵循 KDE 原生交互（选中 + 点应用才生效）；
4. 聚合页**不做任何开关控件**，只读展示当前开关状态。

### 1.2 用户决定（8 项，全部经确认）

| # | 决定 |
|---|---|
| D1 | 聚合入口放在**动效下拉**（条目 + 行尾齿轮），不是窗口管理分类 |
| D2 | 聚合页范围 = **19 项勾选 + 每项全部参数可编辑** |
| D3 | 勾选语义反转为**勾上 = 参与随机**（默认全勾；内部以 `Blacklist = 未勾选集合` 反向映射，配置格式不变） |
| D4 | 下拉 = **总开关**：选「随机特效」= 启用随机；选 KWin 内置项 = 随机关闭、回退内置动画 |
| D5 | 下拉选择是**草稿态**，点「应用/确定」才提交（与 KDE 行为一致，不自造提交时机） |
| D6 | **开关完全遵循 KDE**：不新增任何自建开关控件与平行状态，我方只读跟随 |
| D7 | 参数渲染方式 = **自渲染**（读各特效 `main.xml` 动态生成控件），不嵌入上游 `config.ui` |
| D8 | **旧入口移除**：「系统设置 → 窗口管理 → Burn Window」不再保留，齿轮为唯一入口 |

### 1.3 硬约束

- **不修改上游源码**：只改构建/安装产物（与既有注入流程同一边界）。
- 19 个特效必须**保持可加载、可随机播放**（隐藏仅针对两个设置 UI，不针对运行时）。
- `sudo` 凭据仅经 `SUDO_PASSWORD` 环境变量注入，任何文件不得硬编码。
- TDD：每项改动先失败测试后最小实现；全量 8 套回归为完成门槛。
- e2e 必须最后单独串行（其采样窗口对并行 D-Bus 操作敏感，既有 Ruling）。

---

## 2. 方案选型

### 方案 A：占位特效 + `isEffectLoaded` 同步跟随 ✅ **选定**

新增占位特效 `kwin6_effect_bmw_random`（显示名「随机特效」）占据动效下拉条目；19 个 BMW 特效经 metadata 双改造从两个设置 UI 隐藏但保持常驻加载；仲裁逻辑在播放前同步查询占位是否已加载。开关状态唯一真相源是 KDE 写的 `[Plugins]` 键。

### 方案 B：19 个留在 KDE 互斥组，由 ButtonGroup 联动管 Enabled ❌ 排除

`setData` 同组禁用循环按 `exclusiveGroup` 匹配且遍历 source model（`effectsmodel.cpp:193-211`），而 internal 项根本不进模型（`shouldStore` 在源头过滤）。要参与联动就必须渲染在下拉里 → 下拉出现 20 行，违反 D1。

### 方案 C：自建开关存配置文件 ❌ 排除

违反 D6（用户明确否决）。且调研证实因果链不存在：KCM `save()` 只由本页 OK/Apply 触发（`kabstractconfigmodule.h:112-116`），「下拉选中 → 我方 KCM 立即联动」这条链不成立。

---

## 3. 第 1 节：架构与组件 ✅ 已确认

### 3.1 组件清单

| 组件 | 职责 | 变更类型 |
|---|---|---|
| **C1 占位特效** `kwin6_effect_bmw_random` | 占据下拉条目；作为开关状态标识；齿轮指向聚合页 | 新增（我们自产，随 install 写入） |
| **C2 metadata 双改造** | 19 个特效从动效下拉与桌面特效列表同时隐藏 | 扩展 inject.py |
| **C3 聚合 KCM** | 19 项勾选 + 全参数自渲染编辑；只读开关状态展示 | 重构 kcm/ |
| **C4 install.sh** | 新增占位写入、metadata patch、KCM 落点变更、旧落点清理 | 扩展 |
| **C5 uninstall.sh** | 与 C4 对称：metadata 还原、占位删除、**占位的 `[Plugins]` Enabled 条目清理**（占位 id 不在 Pool 内，既有清理收集不到，必须显式加项）、新落点 KCM 删除 | 扩展 |

### 3.2 C1 占位特效字段

```json
{
  "KPackageStructure": "KWin/Effect",
  "KPlugin": {
    "Name": "随机特效",
    "Description": "随机播放 Burn-My-Windows 的窗口开/关动画",
    "Icon": "preferences-system-windows-effect",
    "Category": "Window Open/Close Animation",
    "Id": "kwin6_effect_bmw_random",
    "License": "GPLv3",
    "EnabledByDefault": false,
    "ServiceTypes": ["KWin/Effect"]
  },
  "X-KWin-Exclusive-Category": "toplevel-open-close-animation",
  "X-KDE-ConfigModule": "kcm_burnwindow",
  "X-Plasma-API": "javascript",
  "X-Plasma-MainScript": "code/main.js",
  "X-KDE-Ordering": 61
}
```

- **`X-KWin-Exclusive-Category`** → 进入动效下拉（filter 只比较此值，`effectssubsetmodel.cpp:56-73`）。
- **`X-KDE-ConfigModule`** → 非 `kcm_kwin4_genericscripted` 值被直接接受（`effectsmodel.cpp:303-313`），加载链 `KPluginMetaData("kwin/effects/configs/" + value)` → `KCModuleLoader`，明确支持 QML KCM（`kquickconfigmoduleloader.cpp:18-55`）。
- **`EnabledByDefault: false`** → 与内置 fade 一致；初始未选中（当前状态下用户需在下拉选中并应用才开启随机）。
- **`main.js`**：零动画实现（不响应 `slotWindowAdded`）。它只是状态标识，抽签与播放全部由 19 个特效完成 —— 否则会与 winner 双重动画。
- 模板存放：`placeholder/kwin6_effect_bmw_random/{metadata.json, contents/code/main.js}`；install 解包后复制进 effects 目录。

### 3.3 C2 metadata 双改造（防御性）

对 19 个特效的 `metadata.json`：

| 字段 | 改前 | 改后 | 依据 |
|---|---|---|---|
| `X-KWin-Internal` | 无 | `"true"` | `shouldStore` 首行拦截（`effectsmodel.cpp:692-715`）→ 两个 KCM 模型均不收录；**运行时不读此字段**，`effectloader` 只看 `[Plugins] <id>Enabled`（`effectloader.cpp:51-66`）；官方先例 `sessionquit` |
| `X-KWin-Exclusive-Category` | `toplevel-open-close-animation` | `bmw-hidden` | 双保险：调研报告对该字段与 internal 的叠加效果存在两种表述，改组名消除分歧（改后无论 internal 是否生效，filter 均不匹配） |

- **载体**：扩展 `lib/inject.py`（复用其幂等与 `.orig` 备份机制），新增 `metadata.json.orig`。
- **幂等**：已含 `X-KWin-Internal` 且组名已改 → 跳过。
- **还原**：uninstall 还原 `metadata.json` 并删除 `.orig`（清理项清单 +2）。

### 3.4 三条数据流

```
① 开关流（D4/D5/D6，完全遵循 KDE）
 下拉选「随机特效」→ 点应用 → EffectsModel::save() 写
 [Plugins] kwin6_effect_bmw_randomEnabled=true（带 KConfig::Notify）
 → KConfig D-Bus 通知（kconfig.cpp:523-534）
 → KWin KConfigWatcher（effecthandler.cpp:133）→ EffectsHandler::configChanged
    只处理 [Plugins] *.Enabled → 自动 load/unload 占位（effecthandler.cpp:1567-1600）
 → 19 个仲裁入口同步查询 effects.isEffectLoaded('kwin6_effect_bmw_random')
    → false 直接不播（关闭态）；true 进入既有抽签逻辑

② 勾选流（D3）
 聚合页 CheckBox → save() → Blacklist = 未勾选集合 → 写 burn-window-randomrc
 → 触发既有 apply 链路：inject.py 重注入（黑名单内联进 19 个 main.js）→ reload 19 个

③ 参数流（D7）
 聚合页控件 → save() → kwriteconfig6 写 [Effect-<id>] 各键
 → 逐 id qdbus6 org.kde.KWin /Effects reconfigureEffect <id>
    （必须：ScriptedEffect::reconfigure 才重读配置并发 configChanged
      scriptedeffect.cpp:630-637；[Effect-*] 组被 EffectsHandler::configChanged
      显式忽略 effecthandler.cpp:1569-1571）
```

### 3.5 关键设计事实（链路决定，非取舍）

1. **19 个常驻加载**：占位被卸载时其 JS 不运行，没有合法通道反向卸载 19 个；而 19 个常驻、只查占位状态的链路完全通畅。关闭态代价 = 每次窗口事件 19 次 `isEffectLoaded` 查询后即 return（微秒级，无动画开销）。
2. **下拉选中的提交时序**：`setData` 只改内存 `changed` 标记（`effectsmodel.cpp:185-190`），落盘仅发生在点应用/确定 —— 与 D5 用户观察一致。
3. **选中占位不误伤内置项**：当前 fade/scale 均已是 Disabled（`changed=false`，save 跳过），且 19 个已移出组（3.3 的组名改写），同组仅剩 fade/scale/占位 → 键变化仅 `bmw_randomEnabled=true` 一项。

---

## 4. 第 2 节：聚合页详细设计 ✅ 已确认

### 4.1 KCM 落点（D8）

| 项 | 旧（移除） | 新（唯一） |
|---|---|---|
| `.so` 路径 | `/usr/lib/qt6/plugins/plasma/kcms/systemsettings/kcm_burnwindow.so` | `/usr/lib/qt6/plugins/kwin/effects/configs/kcm_burnwindow.so` |
| 注册方式 | systemsettings 模块扫描 | 齿轮经 `KPluginMetaData("kwin/effects/configs/" + id)` 加载（无需 desktop 文件） |

- CMake 构建产物路径随 `kcm/CMakeLists.txt` 的 install 目标同步调整。
- install.sh 新增**旧落点清理**（存在则删除，含 sudo），避免两个入口并存违反 D8。
- KCM 安装仍属提权步骤，保持「提权最后、失败即中止」的既有顺序（RF4）。

### 4.2 C++ 侧（`kcm/kcm.cpp` 扩展）

1. **参数模型解析**：扫描 `EFFECTS_DIR/*/contents/config/main.xml`，解析 `<entry name type default>` 与 `<min>/<max>/<choices>`；解析失败的特效跳过并 `warn`（不静默）。
2. **暴露给 QML** 的模型：`[{ effectId, displayName, participating, params: [{name, type, default, value, min, max}] }]`。
3. **开关状态只读展示**：QDBus 同步查询 `org.kde.KWin /Effects loadedEffects` 是否含 `kwin6_effect_bmw_random` → 顶部徽标「已启用/未启用」。**这是显示器，不是开关**（D6）。
4. **`save()` 三段**：
   - 勾选段：`Blacklist = 未勾选集合` → 写 `burn-window-randomrc` → 执行既有 apply 脚本（超时 15s、stderr 原文展示的既有实现保留）；
   - 参数段：`kwriteconfig6 --file kwinrc --group Effect-<id> --key K --type T V`（类型对齐 main.xml 的 kcfg 定义）；
   - 生效段：对每个有参数变更的 id 调 `reconfigureEffect <id>`，失败仅警告（参数已落盘，下次加载生效）。
5. 参数写入语义与 `kcm_kwin4_genericscripted` 等价：其保存即 `KCoreConfigSkeleton::save()` 逐 main.xml 键写入、无附加标记（`kcoreconfigskeleton.cpp:1367`、写标志为 `Normal`）。

### 4.3 QML 侧（`kcm/ui/main.qml` 重构）

```
SimpleKCM
├─ 顶部：使用说明（勾上=参与随机）+ 开关状态只读徽标
└─ Repeater（19 项）
   ├─ CheckBox「参与随机」（checked 绑定模型，勾上=参与，D3）
   ├─ 「参数 ▸」展开按钮
   └─ 参数面板（按 type 动态控件，D7）
        UInt/Int → SpinBox（min/max 来自 main.xml）
        Double  → SpinBox（小数步进）
        Color   → ColorButton
        Bool    → CheckBox
        String  → TextField
```

- 现有 19 项黑名单 Repeater 结构保留，语义与映射方向按 D3 反转；既有 `BMW_KCM_*` console.log 诊断输出模式保留（测试断言通道）。
- 既有「Apply 子进程超时检测 / stderr 原文 / 按钮状态恢复」能力保留（RF5，`applyRunning` 接通由 general 修复线完成，见第 7 章协调项）。

### 4.4 仲裁逻辑扩展（`lib/arbiter.js`）

```js
// 新常量（注入时内联）
const BMW_PLACEHOLDER_ID = 'kwin6_effect_bmw_random';

// bmwShouldPlay 入口第一道闸：开关关闭 → 不播任何特效
if (!effects.isEffectLoaded(BMW_PLACEHOLDER_ID)) return false;
```

- `effects` 为 effect JS 全局对象（`scriptedeffect.cpp:260` 经 `newQObject` 暴露，slots 可用）；`isEffectLoaded` 是 `Q_SCRIPTABLE` 且直查内存列表（`effecthandler.h:1075`、`effecthandler.cpp:1243-1249`）；同机制的 `readConfig` 已被上游 BMW 实际使用 —— 可用性依据充分（见 7.1 待验证项 V2）。
- 检查顺序：**开关 → 空池 → 抽签 → winner 复用校验**（后者为 general 修复线 M-4 范围）。
- `bmwPickWinner` 不受影响（纯函数，池与黑名单由注入时内联）。

---

## 5. 第 3 节：错误处理与测试策略 ✅ 已确认

### 5.1 错误处理

| 场景 | 行为 |
|---|---|
| 齿轮点开但 KCM 未安装（`--skip-sudo`） | `KCModuleLoader` 返回 `KCModuleError` → 对话框显示错误页（不崩溃，`kcmoduleloader.cpp:84-107`） |
| `main.xml` 缺失/解析失败 | 该特效跳过 + warn，其余照常 |
| 参数写入失败 | `save()` 报错并保留 needsSave，可重试 |
| `reconfigureEffect` 失败 | 警告，参数已落盘 |
| 19 项全不勾（空池） | 不播任何特效（既有 arbiter 空池语义） |
| 开关关闭时改配置 | 正常保存（配置写入不依赖开关状态） |
| 占位 main.js 加载失败 | 见 V1 待验证项；实现时以测试断言兜底（见 5.2-2） |

### 5.2 测试策略（TDD，逐项先失败后实现）

1. **metadata 双改造**：19 个断言含 `X-KWin-Internal:true` 且组名已改；幂等（二次 patch 字节不变）；`metadata.json.orig` 备份存在；卸载后还原且 `.orig` 删除。（扩展 `test_install` / `test_uninstall`）
2. **占位特效**：metadata 字段断言（Id/Name/Exclusive/ConfigModule/EBD）；`node --check` 通过；安装后目录存在；**加载后不产生动画**（e2e：开关开启且 winner 非占位时 activeEffects 只含 19 个之一）；卸载后目录删除 **且 `[Plugins] kwin6_effect_bmw_randomEnabled` 条目被清除**（对应 C5 补项，防止残留）。
3. **KCM 落点**：新路径 `.so` 存在；旧 `systemsettings` 路径不存在（D8）。
4. **聚合页 C++**：构造 `main.xml` fixture 测类型解析（UInt/Double/Color/Bool/String + min/max）；勾选↔Blacklist 反转映射断言；参数写入值断言（读回 kwinrc）；`reconfigureEffect` 调用经诊断输出断言。
5. **e2e 开关链路**：
   - 开：`kwriteconfig6 --notify --file kwinrc --group Plugins --key kwin6_effect_bmw_randomEnabled true`（带 `--notify` 才触发 KConfigWatcher，与 KDE `save()` 写键等价）→ 断言占位进入 `loadedEffects` → 开/关窗口采样到 19 个特效之一；
   - 关：删除该键 + notify → 断言占位离开 `loadedEffects` → 采样无任何 `kwin6_effect_*` 动画；
   - 恢复动作纳入 `trap`（既有 Minor-9 修复方向）。
6. **全量回归**：8 套测试全绿，e2e 最后单独串行。

---

## 6. 调研验证记录（KWin v6.7.5 源码核对，12 点）

| # | 技术点 | 判定 | 主依据 |
|---|---|---|---|
| 1 | 下拉齿轮挂自定义 KCM | ✅ | `effectsmodel.cpp:303-313`、`effectsmodel.cpp:618-638`、`kquickconfigmoduleloader.cpp:18-55` |
| 2 | KCM 部署路径约束 | ⚠️ 有条件 | `KPluginMetaData("kwin/effects/configs/"+id)` 的 QPluginLoader 解析语义；本机 `/usr/lib/qt6/plugins/kwin/effects/configs/` 现有 16 个 `.so` |
| 3 | 19 个从动效下拉消失 | ✅ | `effectssubsetmodel.cpp:56-73`（filter 只比较组名） |
| 4 | 19 个从桌面列表消失且保持加载 | ✅ | `effectsmodel.cpp:692-715`（internal 首行拦截）；`effectloader.cpp:51-66`；官方 `sessionquit` |
| 5 | 下拉作总开关 | ✅ | `effectsmodel.cpp:501-536`（save 带 Notify）→ `kconfig.cpp:523-534` → `kconfigwatcher.cpp:84-121` → `effecthandler.cpp:1567-1600` |
| 6 | 19 个 JS 同步感知 | ✅ | `effecthandler.h:1075`（Q_SCRIPTABLE）、`effecthandler.cpp:1243-1249`、`scriptedeffect.cpp:260`；`callDBus` 为异步（`scripting.cpp:352`）不可用 |
| 7 | 我方 KCM save 联动写 19 键 | ❌ 不存在 | `kabstractconfigmodule.h:112-116`（save 只由本页按钮触发）—— D6 下无需此链 |
| 8 | 下拉选中即写盘 | ❌ 草稿态 | `effectsmodel.cpp:185-190`；点应用才 `save()` —— 与 D5 观察一致 |
| 9 | 选占位不误伤内置键 | ⚠️ 有条件 | fade/scale 已 Disabled；**前提是 19 个已移出组**（3.3 双改造） |
| 10 | 聚合页直写参数组 | ⚠️ 有条件 | 写后必须 `reconfigureEffect`（`scriptedeffect.cpp:630-637`；`effecthandler.cpp:1569-1571` 忽略非 Plugins 组） |
| 11 | Ordering/Category 字段影响 | ✅ 无 | 不参与互斥/过滤判定 |
| 12 | `kwin4_effect_animationsSuiteEnabled` | ℹ️ 无效残留 | KWin 6 源码零命中、本机无对应特效目录 |

附：`setData` 同组禁用循环遍历整个 source model（`effectsmodel.cpp:193-211`）；genericscripted 的参数生效同样靠 `reconfigureEffect`（`genericscriptedconfig.cpp:161-168`）。

---

## 7. 风险、待验证项与协调

### 7.1 【待验证】清单（实现期第一优先级）

| # | 项 | 验证方式 | 失败预案 |
|---|---|---|---|
| V1 | 空实现 `main.js`（无 `slotWindowAdded`）能否被 KWin 正常加载 | 安装后 `loadedEffects` 断言 + journal 无加载错误 | 加最小 `function init() {}` 与空回调骨架 |
| V2 | `effects.isEffectLoaded` 在注入上下文实际可用 | arbiter 单测 mock + e2e 开关链路实测 | 备选 `effects.loadedEffects` 属性（同为同步暴露，`effecthandler.h:124`） |
| V3 | KCM `.so` 落 `kwin/effects/configs/` 后齿轮实际能打开 | 装后手动点齿轮 + 测试断言 `KCMultiDialog` 无错误页 | 检查 `.so` 内嵌 JSON（`K_PLUGIN_FACTORY_WITH_JSON`）与加载日志 |
| V4 | 齿轮 `ConfigurableRole` 对自定义 `X-KDE-ConfigModule` 是否为 true（决定按钮 enabled） | V3 同时验证 | 查 `ConfigurableRole` 赋值源；必要时补 metadata 字段 |

### 7.2 与 general 修复线的协调

- general（后台）正在修复 reviewer 的 6 Major + 3 Minor，涉及 `install.sh`、`kcm/`、`tests/`、`lib/arbiter.js` —— **与本设计改同批文件**。
- 协调规则：**实现必须等 general 完成并 commit 后开工**（spec/plan 阶段只写文档，不冲突）。
- 重叠点：M-4（winner 复用校验）与 4.4 的开关闸在 `arbiter.js` 同函数；M-6（applyRunning 接通）与 4.3 的按钮状态同属 `kcm/`。实现时以其提交为基线增量开发。

### 7.3 范围外（YAGNI）

概率/权重配置、参数导入导出、动画预览、KWin 5 兼容、非 Arch 发行版适配、聚合页搜索/过滤。

---

## 8. 决策记录

| 决策 | 结论 | 依据/时点 |
|---|---|---|
| 聚合入口位置 | 动效下拉 + 齿轮 | D1 |
| 页面范围 | 勾选 + 全参数 | D2 |
| 勾选方向 | 勾上=参与（Blacklist 反向映射） | D3 |
| 总开关 | KDE 下拉唯一，无自建开关 | D4/D6 |
| 提交时机 | 点应用才生效（不自造） | D5 + 源码 `effectsmodel.cpp:185-190` |
| 参数渲染 | 自渲染（main.xml 驱动） | D7 |
| 旧入口 | 移除，齿轮单一入口 | D8 |
| 19 个加载策略 | 常驻加载 + 同步查占位 | 3.5-1（链路唯一解） |
| metadata 改造 | internal + 改组名双保险 | 3.3（调研表述分歧的消解） |
| 方案 | A（占位 + isEffectLoaded） | 第 2 章 |

---

## 附录 A：调研依据链接（v6.7.5 / kconfig 6.30.0 / kcmutils 6.30.0）

- 动效下拉：https://invent.kde.org/plasma/kwin/-/blob/v6.7.5/src/kcms/animations/ui/main.qml#L110 、#L141 ；`AnimationComboBox.qml#L45`、`#L97`
- 模型与 save：https://invent.kde.org/plasma/kwin/-/blob/v6.7.5/src/kcms/common/effectsmodel.cpp#L185 、#L193 、#L300 、#L501 、#L618 、#L692 ；`effectssubsetmodel.cpp#L56`
- KWin 运行时：https://invent.kde.org/plasma/kwin/-/blob/v6.7.5/src/effect/effectloader.cpp#L51 ；`effecthandler.cpp#L133`、`#L1243`、`#L1567`；`effecthandler.h#L124`、`#L1075`；`scriptedeffect.cpp#L246`、`#L260`、`#L630`；`scripting.cpp#L352`
- 配置通知链：https://invent.kde.org/frameworks/kconfig/-/blob/v6.30.0/src/core/kconfig.cpp#L523 ；`kconfigwatcher.cpp#L84`；`kwriteconfig.cpp#L37`
- KCM 加载：https://invent.kde.org/frameworks/kcmutils/-/blob/v6.30.0/src/kcmoduleloader.cpp#L84 ；`kcmultidialog.cpp#L313`；`kabstractconfigmodule.h#L112`
- Qt：https://doc.qt.io/qt-6/qjsengine.html#newQObject ；https://doc.qt.io/qt-6/qsortfilterproxymodel.html
- 官方 internal 先例：本机 `/usr/share/kwin-wayland/effects/sessionquit/metadata.json`

## 附录 B：新增/变更文件速查

```
placeholder/kwin6_effect_bmw_random/     # C1 模板（新增）
  metadata.json / contents/code/main.js
lib/inject.py                             # C2 扩展：metadata 双 patch + .orig 备份
lib/arbiter.js                            # 4.4 开关闸 + 占位 id 常量
kcm/CMakeLists.txt / kcm/kcm.cpp / kcm/ui/main.qml   # C3 落点变更 + 聚合页
kcm/kcm_burnwindow.json                   # 属 systemsettings 注册用；新落点加载链读 .so 内嵌 JSON，不读此文件 → 实现时从安装步骤移除（D8 一并清理）
install.sh                                # C4：占位写入、metadata patch、新落点 KCM、旧落点清理
uninstall.sh                              # C5：对称清理（metadata 还原、占位删除、新落点 KCM）
tests/test_install.sh / test_uninstall.sh / test_kcm_build.sh / test_e2e.sh / arbiter.test.mjs  # 5.2
```
