# Burn-My-Windows 随机特效包装层 —— 设计文档

| 项 | 值 |
|---|---|
| 日期 | 2026-09-29 |
| 状态 | 待审阅 |
| 路径 | architectural（新子系统） |
| 目标环境 | KDE Plasma 6.7.5 + KWin 6.7.5 + Wayland（Arch Linux，本机，已确认即目标环境） |
| 上游 | https://github.com/Schneegans/Burn-My-Windows （镜像 `https://ghfast.top/https://github.com/Schneegans/Burn-My-Windows.git`） |

**证据图例**（本文档所有结论按此分级）

- 【实测】本会话在本机实机跑出，附原始输出
- 【源码】KDE / Qt / systemd 官方源码或文档，附 URL
- 【上游】Burn-My-Windows 上游仓库文件
- 【待验证】尚未验证，列入风险清单
- 【重建】由会话记录重建、需审阅者重点核对的段落

---

## 1. 需求与约束

### 1.1 目标

为 Burn-My-Windows 的 KDE/Plasma 版做**独立包装层**：

1. 一次性安装全部 19 个特效
2. 每次窗口**打开**时从特效池随机选取一个特效播放
3. 每次窗口**关闭**时从特效池随机选取一个特效播放
4. 打开与关闭**各自独立随机**（不配对）
5. 通过图形界面勾选黑名单，剔除不想参与随机的特效

### 1.2 硬约束

| 约束 | 来源 |
|---|---|
| **不修改上游源码**，交付形态为独立包装层 | 用户明确要求 |
| 黑名单方式，默认全部 19 个进池 | 用户明确要求 |
| 黑名单载体为**自定义 KCM 系统设置模块**（用户在 4 个选项中选定） | 用户决策 |
| 全程中文交流，结论必须附可追溯依据 | 用户明确要求 |
| 禁止猜测性表述（"可能/大概/应该/也许/或许/似乎/估计/按理说"），无依据时须写"未找到依据，无法确认" | 用户明确要求 |

### 1.3 上游现状（调研结论）

- 官方 KDE 支持始于 **v17（2022-06-30）**，依赖 kwin MR 2227
- "只能选一个特效"的根因是 **`X-KWin-Exclusive-Category` + KCM 层互斥**，位于上游 `src/kcms/common/effectsmodel.cpp:193-205`；**运行时 `effectloader.cpp` 无互斥**
- 上游 `build.sh` 末尾产出合集包 `burn_my_windows_kwin6.tar.gz`
- 上游 issue #200 中作者表态"（随机化）不在 KDE 版范围"，并指向 bugs.kde.org/show_bug.cgi?id=464322

---

## 2. 方案选型

### 方案 A：构建期注入仲裁逻辑 ✅ **选定**

在构建/安装阶段，向 19 个特效的 `main.js` 注入仲裁代码，由注入代码在运行时决定"本窗口本次播放哪个特效"。

- **优点**：仲裁逻辑与特效同生命周期，时机确定；不依赖外部进程；不改上游仓库文件（只改安装到用户目录的副本）
- **代价**：黑名单变更需重新注入（→ `install.sh --apply-config`）

### 方案 B：外部脚本动态 `loadEffect`/`unloadEffect` ❌ 排除

由外部脚本监听窗口事件，动态加载/卸载特效。

- **排除理由**：加载时机不可控 —— 窗口打开事件与特效就绪之间存在竞态，无法保证特效在动画窗口出现前生效

### 方案 C：Fork 上游 ❌ 排除

- **排除理由**：与"不修改上游源码"的硬约束直接冲突

---

## 3. 第 1 节：整体架构与组件边界 ✅ 已确认

### 3.1 组件清单

```
┌─────────────────────────────────────────────────────────────┐
│ burn-window（独立包装层，不改上游仓库）                       │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  install.sh ──────────────┬───────────────┐                 │
│  （构建/注入/安装）        │               │                 │
│       │                   │               │                 │
│       ▼                   ▼               ▼                 │
│  ┌──────────┐   ┌──────────────────┐  ┌──────────────┐      │
│  │ 注入代码  │   │ 特效副本          │  │ KCM .so      │      │
│  │ (仲裁逻辑)│──▶│ ~/.local/share/  │  │ 系统设置模块  │      │
│  │          │   │ kwin/effects/    │  │ (黑名单编辑)  │      │
│  └──────────┘   │ 19× main.js     │  └──────┬───────┘      │
│                 └──────────────────┘         │              │
│                                              ▼              │
│                              ~/.config/burn-window-randomrc │
│                              (Pool + Blacklist + ApplyScript)│
└─────────────────────────────────────────────────────────────┘
```

### 3.2 数据流

```
install.sh（首次）
  ├─ 克隆上游 → build.sh 构建 19 特效合集
  ├─ 解包到 ~/.local/share/kwin/effects/
  ├─ 向 19 个 main.js 注入仲裁代码（黑名单以字面量固化）
  ├─ 写 kwinrc [Plugins] 19 个 kwin6_effect_*Enabled=true   ← 重启后仍加载的必要条件
  ├─ 写配置 Pool=... 、ApplyScript=...
  └─ 装 KCM .so 到系统目录 [需 sudo]

KCM（日常使用）
  └─ 读 Pool → 渲染勾选列表 → 写 Blacklist

install.sh --apply-config（黑名单变更后，免 sudo）
  ├─ kreadconfig6 读 Blacklist
  ├─ 重新注入 19 个 main.js（更新黑名单字面量）
  └─ D-Bus unloadEffect/loadEffect 逐个重载

运行时（每次开/关窗）
  └─ 注入的仲裁代码从池中排除黑名单 → Math.random() 选取 winner
     → 通过 window.setData(role, winner) 交给本窗口的动画播放
```

### 3.3 关键机制（全部有实测依据）

| 机制 | 结论 | 证据 |
|---|---|---|
| 跨特效共享通道 | **`window.setData(424242, winner)` / `window.data(424242)` 是唯一可行通道** | 【实测】fire 写 `FROM_FIRE`，incinerate 读到 |
| 打开/关闭独立随机 | open 用 **role 424242**、close 用 **role 424243** | 【实测】open 抽中 fire、close 抽中 incinerate，不同 role 隔离 |
| 信号回调顺序 | 由**加载顺序**决定；同一信号**同步顺序执行，无竞态** | 【实测】 |
| JS 动态属性 | `window.bmwLock` 等 JS 属性**跨特效不共享** | 【实测】不能用作仲裁介质 |
| `window.internalId` / `windowId` | 在 effect JS 中**均为 `undefined`** | 【实测】无法用作窗口标识 |
| `effect.readConfig()` | **只能读 kwinrc 中本特效自己的段** | 【实测】跨 19 个特效无运行时配置共享通道 |
| effect JS 上下文可用能力 | **有** `Math.random()`、`window.setData/data`、`window.windowClass`；**无** `callDBus`、文件 IO | 【实测】`callDBus is not defined` |
| 未仲裁时的行为 | 同一窗口 `activeEffects` 同时含 `kwin6_effect_fire` + `kwin6_effect_incinerate`（叠加播放） | 【实测】证明仲裁必要性 |
| 仲裁原型有效性 | `activeEffects` 统计 fire 30 次 / incinerate 0 次 | 【实测】 |
| 独立随机分布 | 6 次开窗 winner 分布 fire×2 / incinerate×4 | 【实测】 |

### 3.4 池成员（19 个，实测自 `~/.local/share/kwin/effects/`）

| # | ID（= `X-KDE-PluginKeyword`） | 显示名 |
|---|---|---|
| 1 | `kwin6_effect_aura_glow` | Aura Glow [Burn-My-Windows] |
| 2 | `kwin6_effect_doom` | Doom [Burn-My-Windows] |
| 3 | `kwin6_effect_energize_a` | Energize A [Burn-My-Windows] |
| 4 | `kwin6_effect_energize_b` | Energize B [Burn-My-Windows] |
| 5 | `kwin6_effect_fire` | Fire [Burn-My-Windows] |
| 6 | `kwin6_effect_focus` | Focus [Burn-My-Windows] |
| 7 | `kwin6_effect_glide` | Glide [Burn-My-Windows] |
| 8 | `kwin6_effect_glitch` | Glitch [Burn-My-Windows] |
| 9 | `kwin6_effect_hexagon` | Hexagon [Burn-My-Windows] |
| 10 | `kwin6_effect_incinerate` | Incinerate [Burn-My-Windows] |
| 11 | `kwin6_effect_pixelate` | Pixelate [Burn-My-Windows] |
| 12 | `kwin6_effect_pixel_wheel` | Pixel Wheel [Burn-My-Windows] |
| 13 | `kwin6_effect_pixel_wipe` | Pixel Wipe [Burn-My-Windows] |
| 14 | `kwin6_effect_portal` | Portal [Burn-My-Windows] |
| 15 | `kwin6_effect_rgbwarp` | RGB Warp [Burn-My-Windows] |
| 16 | `kwin6_effect_team_rocket` | Team Rocket [Burn-My-Windows] |
| 17 | `kwin6_effect_tv` | TV Effect [Burn-My-Windows] |
| 18 | `kwin6_effect_tv_glitch` | TV Glitch [Burn-My-Windows] |
| 19 | `kwin6_effect_wisps` | Wisps [Burn-My-Windows] |

> ID 与显示名均由各特效 `metadata.json` 实测提取；目录名与 `X-KDE-PluginKeyword` **完全一致**（19/19）。

---

## 4. 第 2 节：KCM 详细设计 ✅ 已确认（含 P1 + 模式 B 决策）

### 4.1 KCM 职责边界

**只做一件事：编辑黑名单并持久化。** 不负责注入代码、不负责安装特效。

上游 19 个特效的 ID 清单**不在 KCM 源码里硬编码**，改由 `install.sh` 写入配置的 `Pool` 键（见 4.2），这样上游增删特效时 KCM 无需重编译。

### 4.2 黑名单真相源

**`~/.config/burn-window-randomrc`**（ini 格式）：

```ini
[General]
# 由 install.sh 写入，KCM 只读
Pool=kwin6_effect_aura_glow,kwin6_effect_doom,...
# 由 KCM 读写
Blacklist=kwin6_effect_pixel_wipe
# 由 install.sh 写入，KCM 执行 Apply 时调用
ApplyScript=/home/<user>/.local/libexec/burn-window-apply-config.sh
```

**选独立文件而非 kwinrc 自定义段的理由**：kwinrc 是 KWin 运行时的活配置文件（【实测】本机 `kwinrc` 含 `[Plugins]`、`[Effect-kwin6_effect_fire]` 等段且由 KWin 持续维护），KConfig 并发写同一文件存在覆盖风险。【待验证：并发覆盖的实际发生概率】

**解析工具**：`kreadconfig6 --file burn-window-randomrc --group General --key Blacklist`
【实测】`/usr/bin/kreadconfig6` 存在，`--file / --group / --key` 参数齐全。

### 4.3 安装路径策略 —— 方案 P1（用户选定，已实测验证）

```
KCM .so → /usr/lib/qt6/plugins/plasma/kcms/systemsettings/kcm_burnwindow.so   [需 sudo 一次]
配置    → ~/.config/burn-window-randomrc                                      [免 sudo]
特效    → ~/.local/share/kwin/effects/kwin6_effect_*/main.js                  [免 sudo]
apply 脚本 → ~/.local/libexec/burn-window-apply-config.sh                     [免 sudo]
```

**依据**：

- 【源码】`KPluginMetaData::findPlugins` 相对路径分支走 `QCoreApplication::libraryPaths()` —— `kpluginmetadata.cpp:65`
  https://invent.kde.org/frameworks/kcoreaddons/-/blob/master/src/lib/plugin/kpluginmetadata.cpp
- 【源码】`libraryPaths()` = Qt 默认插件目录 + `QT_PLUGIN_PATH`
  https://doc.qt.io/qt-6/qcoreapplication.html#libraryPaths
- 【实测】`qtpaths6 --plugin-dir` → `/usr/lib/qt6/plugins`；系统 57 个 KCM 全部位于 `.../plasma/kcms/systemsettings/`

**实测验证结果**：

| 探针 | 结果 |
|---|---|
| 装入系统路径后，**不带** `QT_PLUGIN_PATH` 的 `systemsettings --list` | ✅ 列出 `kcm_burnwindow - Configure random window open/close effects blacklist` |
| **不带** `QT_PLUGIN_PATH` 实际加载（`/proc/<pid>/maps`） | ✅ dlopen `/usr/lib/qt6/plugins/plasma/kcms/systemsettings/kcm_burnwindow.so` |
| `kcmshell6 kcm_burnwindow` 按名加载 | ✅ 成功 |
| 基线对照（装入前） | ✅ 未列出 —— 证明差异确实来自 P1 路径 |
| 用户级 `~/.local/lib/qt6/plugins` **不带** `QT_PLUGIN_PATH` | ❌ 不被发现（否决 P3 免环境变量路线） |

**关键推论**：`install.sh` 只有「安装 KCM .so」一步需要 root；**注入与特效重载全部免 sudo**，因此模式 B 中 KCM 调用的子命令无需提权，避免 KCM 内部处理密码。

**被排除的替代方案**：

- **P2 用户级 + 环境变量**（`~/.config/environment.d/` 注入 `QT_PLUGIN_PATH`）：免 sudo 但需重新登录，且 `QT_PLUGIN_PATH` 影响整个会话。【源码】`startplasma.cpp:291-307` 主动从 systemd user 导入且 `QT_PLUGIN_PATH` 不在过滤名单 https://invent.kde.org/plasma/plasma-workspace/-/blob/master/startkde/startplasma.cpp —— **可行但未被选中**
- **P3 用户级免环境变量**：❌ 已否决 —— `externalmodules` 4 个候选路径（`kservices6/`、`kservices5/`、`plasma/systemsettings/externalmodules/`、`plasma/kcms/systemsettings/`）**全部探测失败**，本机 systemsettings 6.7.5 二进制中无 `externalmodules` 路径常量
- **`~/.profile` / `~/.bash_profile`**：❌ 对 Plasma 会话**无效** ——【源码】`startplasma.cpp` 全文仅 `runEnvironmentScripts()` 一处 `sourceFiles` 调用

### 4.4 生效链路 —— 模式 B（用户选定）

```
你勾选 → Blacklist 写入配置
       → KCM Apply → QProcess: ~/.local/libexec/burn-window-apply-config.sh
                     ├─ kreadconfig6 读 Blacklist
                     ├─ 重新注入 19 个特效 main.js（更新黑名单字面量）
                     └─ D-Bus unloadEffect/loadEffect 逐个重载
       → 下次开/关窗按新黑名单随机
```

**子命令划分**：

| 子命令 | 内容 | 权限 | 调用方 |
|---|---|---|---|
| `install.sh`（默认） | 构建 → 注入 → 装特效 → **写 `kwinrc` 19 个 `Enabled=true`** → **装 KCM .so** → 写配置 | 装 .so 那步需 sudo | 用户（终端） |
| `install.sh --apply-config` | 读配置 → 重新注入 → **重载 19 个特效** | **免 sudo** | **KCM（QProcess）** |

**为什么 apply 脚本要复制到 `~/.local/libexec/`**：源码目录存在被移动或删除的风险；`install.sh` 安装时把 apply 逻辑复制为固定路径脚本，并把该绝对路径写入配置 `ApplyScript=`，KCM 只认配置里的路径。

**KCM 侧 Apply 流程**（`kcm.cpp`）：

1. 持久化 `Blacklist` 到配置
2. `QProcess::start(配置中的 ApplyScript)`，`waitForFinished` 带超时
3. 退出码 0 → 提示成功；非 0 → 展示 stderr 内容
4. 执行期间禁用 Apply 按钮，结束后恢复

**对 apply 脚本的硬约束**：必须**完全非交互**（不得 prompt）、退出码语义明确、诊断信息走 stderr —— 否则 KCM 端无法反馈。

**保留的取舍**（第 1 节已确认）：黑名单变更**不即时生效**，必须经过 apply-config 重新注入。

### 4.5 生效链路实测验证（双向）

**正向**（改 `main.js` → 重载 → 新代码生效）：

注入探针 `throw new Error("BMW_RELOAD_PROBE_A_20260929")` 到 `main.js` 顶部 → `unloadEffect` → `loadEffect`：

```
9月 29 10:35:31 jie-laptop kwin_wayland[1044]: /home/jie/.local/share/kwin/effects/kwin6_effect_fire/contents/code/main.js:1: error: BMW_RELOAD_PROBE_A_20260929
```

- `unload` 后 `isEffectLoaded: false`；`load` 后 `isEffectLoaded: false`（脚本抛错导致加载失败，符合预期）
- journal 在 **`main.js:1`** 出现探针 → **KWin 重新读取了磁盘文件**

**反向**（恢复 → 重载 → 恢复生效）：

恢复备份 → `unload` → `load` → `loadEffect=true`、`isEffectLoaded=true`、journal **零**新探针、`diff` 与原始备份**完全一致**。

**结论：模式 B 的「apply-config 改 `main.js` → D-Bus 重载即生效」链路成立，无需注销重登。**

### 4.6 C++ 侧

```cpp
// kcm.h —— 构造函数必须 public 显式转发，不能用 using 继承
class BurnWindowKCM : public KQuickConfigModule {
    Q_OBJECT
public:
    explicit BurnWindowKCM(QObject *parent, const KPluginMetaData &metaData);
};

// kcm.cpp
BurnWindowKCM::BurnWindowKCM(QObject *parent, const KPluginMetaData &metaData)
    : KQuickConfigModule(parent, metaData)
{
    setButtons(Apply | Default);
    // 读配置 → 暴露 Pool/Blacklist 给 QML
}

K_PLUGIN_FACTORY_WITH_JSON(BurnWindowKCMFactory, "kcm_burnwindow.json",
                            registerPlugin<BurnWindowKCM>();)
#include "kcm.moc"   // 必需
```

**三个易错点（均有实测依据）**：

| 问题 | 根因 | 修复 |
|---|---|---|
| `registerPlugin<T>()` 模板推导失败 | `kquickconfigmodule.h:270:14: note: declared protected here` —— 构造函数是 `protected`，`using KQuickConfigModule::KQuickConfigModule;` 继承后**保持 protected**，导致 `std::is_constructible` 为 false | public 区显式转发构造（`static_assert` 诊断程序证实此方案有效） |
| `kcm.moc` 缺失 | `K_PLUGIN_FACTORY_WITH_JSON` 要求 `#include "kcm.moc"` | 补 include |
| `KQuickConfigModule` 头文件找不到 | KF6 6.30 拆分：它在 **`KCMUtilsQuick`** 组件（`/usr/include/KF6/KCMUtilsQuick/`），target 为 `KF6::KCMUtilsQuick` | 改链接 target |

### 4.7 QML 侧

QML **硬编码必须在 `ui/` 目录**，否则 `kcmutils_add_qml_kcm` 报 `FATAL_ERROR`；QRC prefix = `/kcm/<target>`（【源码】`/usr/lib/cmake/KF6KCMUtils/KF6KCMUtilsMacros.cmake`）

【实测】QML 真实渲染路径：`qrc:/kcm/kcm_burnwindow/main.qml`

**UI 勾选语义（与需求 1.1.5 对齐）**：**勾选 = 加入黑名单 = 该特效不参与随机**。

- 默认状态：19 项**全部不勾**（= 全部进池，符合"默认全部 19 个进池"约束）
- `checked` 直接反映"是否在黑名单中"，不做取反 —— 避免 UI 语义与数据语义相反

```qml
KCMUtils.SimpleKCM {
    title: i18n("随机特效黑名单")
    // 说明文字明确语义，避免用户误解勾选方向
    QQC2.Label { text: i18n("勾选的特效将被剔除，不参与随机；默认全部参与。") }

    Repeater {
        model: kcm.pool          // C++ 暴露的 QVariantList: [{effectId, displayName}, ...]
        delegate: QQC2.CheckBox {
            text: model.displayName
            checked: kcm.blacklist.includes(model.effectId)   // 勾选 = 已在黑名单
            onToggled: kcm.toggleBlacklist(model.effectId, checked)
        }
    }
}
```

**C++ 侧需暴露的接口**（属性名与 QML 严格对应）：

| 名称 | 类型 | 说明 |
|---|---|---|
| `pool` | `QVariantList`（只读属性） | 从配置 `Pool=` 读入，含 `effectId` + `displayName` |
| `blacklist` | `QStringList`（只读属性） | 从配置 `Blacklist=` 读入 |
| `toggleBlacklist(id, add)` | `Q_INVOKABLE` | 更新内存态并标脏，Apply 时持久化 |

**数据读取策略**：**不在 QML 里读 KConfig**（【待验证：QML 中读写 KConfig 的官方用法，调研标注未找到依据】），改为 **`kcm.cpp` 用 KConfig 读好后以属性暴露给 QML** —— C++ 侧已知可行，规避未验证路径。

### 4.8 构建配置（冒烟测试跑通的写法）

```cmake
cmake_minimum_required(VERSION 3.20)
project(burnwindowkcm)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(ECM 6.0.0 REQUIRED NO_MODULE)      # 必须带版本号，见下
set(CMAKE_MODULE_PATH ${ECM_MODULE_PATH} ${ECM_KDE_MODULE_PATH})

# 顺序关键：必须先创建 Qt6::Core target，KDEInstallDirs6 内部的
# QtVersionOption 才能识别 QT_MAJOR_VERSION=6（否则按 Qt5 查 qmake）
find_package(Qt6 REQUIRED COMPONENTS Core Gui Qml Quick)

include(KDEInstallDirs6)
include(KDECMakeSettings)

find_package(KF6 REQUIRED COMPONENTS KCMUtils CoreAddons I18n Config)

kcmutils_add_qml_kcm(kcm_burnwindow SOURCES kcm.cpp)

target_link_libraries(kcm_burnwindow PRIVATE
    KF6::KCMUtilsQuick
    KF6::KCMUtilsCore
    KF6::CoreAddons
    Qt6::Core Qt6::Gui Qt6::Qml)
```

**四个 CMake 陷阱（均有实测依据）**：

| 陷阱 | 根因 | 修复 |
|---|---|---|
| `CMAKE_LIBRARY_OUTPUT_DIRECTORY is not set` | `KDECMakeSettings.cmake:269` 的条件是 `if (WIN32 OR ECM_GLOBAL_FIND_VERSION VERSION_GREATER_EQUAL 5.38.0)`；不带版本号的 `find_package(ECM REQUIRED)` 使该变量为空 → Unix 分支不执行 | `find_package(ECM 6.0.0 REQUIRED NO_MODULE)` |
| `No Qt5 qmake executable found` | `find_package(Qt6 ...)` 晚于 `include(KDEInstallDirs6)` 时，`QtVersionOption.cmake` 因 `TARGET Qt6::Core` 不存在而 fallback 到 `QT_MAJOR_VERSION=5` | **`find_package(Qt6)` 必须在 `include(KDEInstallDirs6)` 之前** |
| `KDEInstallDirs6` 找不到 | 该文件在 `kde-modules/` 子目录，不在 `modules/` | `CMAKE_MODULE_PATH` 需同时含 `${ECM_MODULE_PATH}` 和 `${ECM_KDE_MODULE_PATH}` |
| `KF6Config.cmake` 聚合入口缺失 | 本机未装 | 用 ECM 模块模式：`/usr/share/ECM/find-modules/FindKF6.cmake` ——【实测】输出 `Found KF6: success (found version "6.30.0")` |

**产物**：`bin/plasma/kcms/systemsettings/kcm_burnwindow.so`（49KB）

【实测】**`.desktop` 不是必需的** —— `systemsettings --list` 列出 71 个模块，而系统 KCM 目录下 `.desktop` 计数 = **0**、`.so` = **57**；移除我的 `.desktop` 后仍被正常列出 → **metadata 内嵌 `.so` 即可**，`kcmdesktopfilegenerator` 生成的 `.desktop` 可不安装。

【待验证：KF6 < 6.30 时 `KQuickConfigModule` 可能仍在 `KF6::KCMUtils` 内】—— `install.sh` 需按 `KF6` 版本做 CMake 条件分支。

---

## 5. 第 3 节：错误处理与测试策略 ✅ 已确认

> ⚠️ **【重建】** 本节内容由会话记录中的可追溯要点重建。审阅时请重点核对是否与当初确认的第 3 节一致，有出入请指出。

### 5.1 观测与调试通道（实测结论）

| 手段 | 结论 | 证据 |
|---|---|---|
| effect JS 的 `console.log` | **不进 journal** | 【实测】早期实验无输出 |
| effect JS 的 `throw` / JS error | **进 journal** | 【实测】`main.js:1: error: ...` |
| KCM 的 QML `console.log/warn/error` | **进 journal** | 【实测】`systemsettings[22353]: BMW_KCM_QML_WARN_OK` —— 注意与 effect JS 环境不同 |
| `callDBus` | effect JS 上下文中**不可用** | 【实测】`error: callDBus is not defined` |
| KWin 截图接口 `org.kde.KWin.ScreenShot2` | 被 Polkit 拦截（`NoAuthorized`），**不可用作观测手段** | 【实测】 |
| 判断特效是否加载 | `isEffectLoaded(name)` 方法返回 bool | 【实测】 |
| 注入后自检 | `loadEffect` 失败返回 `false` | 【实测】 |

### 5.2 分层测试策略

**L1 单元级（不依赖 KWin 运行）**

- `install.sh` 注入器：对样例 `main.js` 注入 → 断言注入点、幂等性、备份还原
- 黑名单解析：`kreadconfig6` 读写往返一致性
- CMake 构建链：configure + build 成功（冒烟测试已建立基线）

**L2 组件级（KCM 独立验证）**

- `kcmshell6` / `systemsettings --list` 能发现 KCM
- `/proc/<pid>/maps` 证实 dlopen 到预期路径
- QML 渲染探针出现在 journal

**L3 集成级（KWin 运行时）**

- 注入探针 `throw` → `unload/load` → journal 出现 `main.js:N: error: <probe>`（证明文件被重读）
- 恢复备份 → `unload/load` → journal 零新探针 + `diff` 一致
- 仲裁有效性：`activeEffects` 统计 winner 分布

**L4 端到端**

- 实际开关窗口，观察 winner 分布（open/close 独立性）
- 黑名单生效验证：把全部 19 个加入黑名单 → **不播放任何特效**（行为定义见 7.2 #1）

### 5.3 失败处理要点

| 场景 | 处理 |
|---|---|
| 注入失败 | 保留 `.main.js.orig` 备份，可还原；`install.sh` 报错并中止，不留下半注入状态 |
| `loadEffect` 返回 `false` | 记录到日志并继续（单个特效失败不应中断整个重载流程） |
| KCM 的 Apply 子进程失败 | 展示 stderr 原文给用户；退出码非 0 视为失败 |
| kwinrc 变更 | 操作前备份 ——【实测】本机已有 `~/.config/kwinrc.bak.20260929085112` |

---

## 6. 验证记录（本会话实测汇总）

| # | 验证项 | 结果 | 关键证据 |
|---|---|---|---|
| 1 | 19 特效合集构建 | ✅ | `burn_my_windows_kwin6.tar.gz` 1.8M |
| 2 | `loadEffect` 可同时加载多个同 category 特效 | ✅ | 运行时 `effectloader.cpp` 无互斥 |
| 3 | 未仲裁时同一窗口特效叠加 | ✅ | `activeEffects` 同时含 fire + incinerate |
| 4 | `window.setData/data` 跨特效共享 | ✅ | fire 写、incinerate 读到 |
| 5 | JS 动态属性跨特效不共享 | ✅ | `window.bmwLock` 失败 |
| 6 | `internalId`/`windowId` 为 undefined | ✅ | effect JS 中均 undefined |
| 7 | 仲裁原型有效性 | ✅ | fire 30 次 / incinerate 0 次 |
| 8 | open/close 独立随机 | ✅ | open→fire、close→incinerate |
| 9 | winner 分布 | ✅ | 6 次开窗 fire×2 / incinerate×4 |
| 10 | KCM 构建链（configure→build） | ✅ | 产物 49KB `.so` |
| 11 | KCM 被 systemsettings 发现 | ✅ | `--list` 输出模块名与描述 |
| 12 | KCM 实际 dlopen | ✅ | `/proc/<pid>/maps` 路径 |
| 13 | KCM QML 真实渲染 | ✅ | journal `qrc:/kcm/kcm_burnwindow/main.qml` |
| 14 | **P1 系统级安装（免环境变量）** | ✅ | 不带 `QT_PLUGIN_PATH` 即发现 + 加载 |
| 15 | **改 `main.js` → unload/load 重载** | ✅ 双向 | journal `main.js:1: error: <probe>` |
| 16 | `.desktop` 非必需 | ✅ | 系统 57 个 KCM 均无 `.desktop` |
| 17 | `kreadconfig6` 可用 | ✅ | `/usr/bin/kreadconfig6` |
| 18 | P3 `externalmodules` | ❌ 否决 | 4 候选路径全部失败 |
| 19 | `~/.profile` 对 Plasma 无效 | ✅ | 【源码】`startplasma.cpp` |
| 20 | **`kwinrc` 无 `Enabled` 条目时动画仍触发** | ✅ | `loadEffect` 后开/关 `kwrite`，`activeEffects` 含 fire **52/250 次采样** |
| 21 | **`loadEffect` 不写 `kwinrc`** | ✅ | `kwinrc` 修改时间保持操作前 `09:16:42` |
| 22 | **重启后需 `kwinrc` 才自动加载** | ✅ | 会话启动时 `loadedEffects` 中 BMW 特效 = **0**（19 个目录已存在） |

---

## 7. 风险与未验证项

### 7.1 【待验证】清单

| # | 项 | 影响 | 处理时机 |
|---|---|---|---|
| 1 | KConfig 写独立配置文件的 KCM 用法 | 中 —— 影响 KCM 实现方式 | 实现阶段 |
| 2 | KF6 < 6.30 无 `KCMUtilsQuick` 组件 | 低 —— 仅影响其他机器构建 | `install.sh` 加版本条件分支 |
| 3 | QML 中读写 KConfig 的官方用法 | 低 —— **已由设计规避**（C++ 读、属性暴露） | 无需处理 |
| 4 | KConfig 并发写同文件的覆盖概率 | 低 —— 已通过选独立文件规避 | 无需处理 |
| 5 | KDE 是否官方支持用户级 `.so` KCM 安装 | 低 —— P1 已选定 | **未找到依据，无法确认**（develop.kde.org KCM 文档页 404） |
| 6 | 池为空时各特效对 `window.data(role)` 返回 `undefined` 的行为 | 中 —— 决定 7.2 #1「不播放特效」能否直接达成 | 实现阶段（黑名单全选场景） |

### 7.2 边界行为定义（原设计缺口，已明确）

| # | 问题 | 决定 |
|---|---|---|
| 1 | 黑名单剔除全部 19 个时 | **池为空 → 不播放任何特效**（黑名单语义的自然结果：用户显式要求全部剔除）。仲裁代码在池为空时直接跳过随机、不设置 `window.setData`，各特效因读不到 winner 而不启动动画。<br>【待验证：池空时各特效对 `data(role)` 返回 undefined 的实际行为】 |
| 2 | KWin 启动时是否自动加载 | **`install.sh` 必须写 `kwinrc [Plugins]` 中 19 个 `kwin6_effect_*Enabled=true`**，否则重启后特效不加载。<br>依据：【实测】会话启动时 `loadedEffects` 中 BMW 特效数 = **0**（尽管 19 个目录存在、`kwinrc [Plugins]` 无相关条目）<br>补充：【实测】运行时 `loadEffect` **不写** `kwinrc`（修改时间不变），且加载后动画正常触发（`activeEffects` 采样 52/250 命中）→ 两件事必须分开处理 |
| 3 | 多显示器 / 每 output 随机独立性 | **不在范围内** —— 每次窗口开/关事件全局随机一次，不按 output 区分。窗口事件本身已绑定其所在 output，不额外引入 per-output 状态 |
| 4 | 上游 `build.sh` 失败 | **中止并报告，不留下半安装状态** —— 构建失败时不写配置、不装 KCM、不改 `kwinrc`；已存在的旧安装保持原样 |

---

## 8. 决策记录

| # | 决策 | 选择 | 依据/时间 |
|---|---|---|---|
| 1 | 仲裁实现方式 | **方案 A：构建期注入** | 用户选定；B 时机不可控、C 违反不改上游 |
| 2 | 黑名单载体 | **自定义 KCM** | 用户在 4 个选项中选定 |
| 3 | 随机语义 | **open / close 各自独立随机** | 用户明确要求 |
| 4 | 池列表固化时机 | **安装期固化进注入代码** | 第 1 节确认；黑名单变更需重跑 `--apply-config` |
| 5 | KCM 安装路径 | **P1 系统级**（需 sudo 一次） | 用户选定，实测验证见 4.3 |
| 6 | 生效模式 | **模式 B：Apply 自动执行脚本** | 用户选定，链路实测见 4.5 |

---

## 附录 A：KWin D-Bus 接口速查（实测修正版）

```
服务: org.kde.KWin    路径: /Effects
接口: org.kde.kwin.Effects    ← 注意小写 kwin，用 org.kde.KWin 会报 No such interface
```

| 类型 | 名称 | 用法 |
|---|---|---|
| 方法 | `loadEffect(name)` | `qdbus6 org.kde.KWin /Effects loadEffect kwin6_effect_fire` → `true`/`false` |
| 方法 | `unloadEffect(name)` | 同上格式 |
| 方法 | `isEffectLoaded(name)` | → `true`/`false` |
| 方法 | `isEffectSupported(name)` / `areEffectsSupported(list)` | |
| 方法 | `reconfigureEffect(name)` | |
| 属性 | `loadedEffects` / `activeEffects` / `listOfEffects` | `qdbus6 org.kde.KWin /Effects org.kde.kwin.Effects.loadedEffects`<br>⚠️ 用 `property` 子命令会报 `Cannot find '.property'` |
| 属性读取注意 | `loadedEffects` 是**已加载**，`activeEffects` 是**正在播放动画** | 特效已加载但无动画窗口时，前者含它、后者不含 |

**已知日志噪音**：

- `Could not find slot EffectsAdaptor::activeEffects` —— 说明 `activeEffects` 是属性不是方法
- `Failed to register with host portal ... Connection already associated with an application ID` —— systemsettings 启动的通用 portal 警告，与 KCM 无关

## 附录 B：路径速查

| 用途 | 路径 |
|---|---|
| 特效池（用户级） | `~/.local/share/kwin/effects/<id>/contents/code/main.js` |
| 特效元数据 | `~/.local/share/kwin/effects/<id>/metadata.json` |
| 黑名单配置 | `~/.config/burn-window-randomrc` |
| apply 脚本 | `~/.local/libexec/burn-window-apply-config.sh` |
| KCM 产物（系统级） | `/usr/lib/qt6/plugins/plasma/kcms/systemsettings/kcm_burnwindow.so` |
| KWin 配置 | `~/.config/kwinrc` |
| Qt 插件默认路径 | `/usr/lib/qt6/plugins`（`qtpaths6 --plugin-dir`） |
| QML 必须所在目录 | `<kcm 源码>/ui/` |
| QRC 路径 | `qrc:/kcm/<target>/<file>` |
