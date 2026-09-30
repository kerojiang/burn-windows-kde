# Burn-My-Windows KDE 随机特效包装层

> **English**: A wrapper layer for [Burn-My-Windows](https://github.com/Schneegans/Burn-My-Windows)
> on KDE Plasma 6 / KWin 6. Instead of always playing the same window
> open/close animation, it randomly picks one of the 19 effects for every
> window event, and ships a Plasma System Settings module (KCM) to manage the
> effect pool, per-effect parameters and a live preview. Install with
> `./install.sh`, remove completely with `./uninstall.sh`. Documentation in
> this repository is written in Chinese.

## 这是什么

Burn-My-Windows 上游为 GNOME/KDE 提供 19 种华丽的窗口开/关动画，但每种特效是独立条目，只能固定启用一种。本项目在其之上加一层**随机包装**：

- 每次窗口打开/关闭，从特效池中**随机抽取**一种播放
- 在 KDE 系统设置里提供配置页（KCM），管理特效池、参数与**实时预览**
- 全部可通过 `install.sh` / `uninstall.sh` 一键安装与**完整卸载**

## 功能特性

| 功能 | 说明 |
|------|------|
| 随机仲裁 | 窗口打开与关闭**各自独立随机**；同一事件由 19 个特效同步回调，用 `window.setData` 先到先得抽签，保证只有一个特效播放（`lib/arbiter.js`） |
| 黑名单 | 勾选的特效参与随机，取消勾选即剔除；支持「全选 / 全不选」批量切换 |
| 动画预览 | 每行带 ▶ 预览按钮：开一个临时窗口播放该特效后自动关闭，不影响当前焦点 |
| 参数配置 | 每行齿轮按钮展开该特效的可调参数（参数项来自上游特效 `main.xml` 声明，如 `Duration`） |
| 总开关 | 配置页顶部「随机特效：已启用 / 已禁用」开关，关闭后窗口开/关不再播放任何 Burn-My-Windows 动画（`arbiter.js` 开关闸早退） |
| 中英双语 | 界面文案英文原文 + 中文译文（`kcm/po/zh_CN.po`），跟随 KDE 语言设置自动切换 |
| 完整卸载 | `uninstall.sh` 清理特效、占位条目、KCM、kwinrc 条目、注入还原、配置与翻译 catalog（共 10 步） |

## 工作原理

1. **构建**：克隆上游仓库（走 `ghfast.top` 镜像）→ `upstream/kwin/build.sh` 构建
   `burn_my_windows_kwin6.tar.gz` → 解包到 `~/.local/share/kwin/effects/`
2. **提取特效池**：从各特效 `metadata.json` **现场提取** id（不硬编码），自动跳过占位条目与无 Burn-My-Windows 锚点的第三方特效
3. **注入仲裁代码**：`lib/inject.py` 向每个特效的 `contents/code/main.js` 注入 4 个锚点（严格幂等，原始文件备份为 `main.js.orig`，可用 `--restore` 还原）
4. **随机决策**：注入的 `lib/arbiter.js` 在每次窗口开/关事件中抽签决定 winner
5. **占位特效条目**：`kwin6_effect_bmw_random`（"随机特效 [Burn-My-Windows]"）提供动效下拉中的唯一入口与总开关载体，其 `X-KDE-ConfigModule` 指向 `kcm_burnwindow`
6. **配置应用**：KCM 的黑名单/参数变更经 `~/.local/libexec/burn-window-apply-config.sh` 重新注入并重载特效，**全程免 sudo**

## 安装

```bash
git clone https://github.com/kerojiang/burn-windows-kde.git
cd burn-windows-kde
./install.sh
```

> 新安装的特效需**重启 KWin（或注销重登）**后动画才完整生效（`install.sh` 收尾提示）。

### 依赖

| 场景 | 依赖命令 |
|------|---------|
| 运行 | `python3`、`node`、`kreadconfig6`、`kwriteconfig6` |
| 构建（首装默认） | `cmake`、`ninja`、`git` |
| 翻译 catalog（可选） | `msgfmt`（缺失时跳过翻译安装，不影响主体） |
| 系统 | KDE Plasma 6 / KWin 6、Qt6、KF6 |

唯一需要 `sudo` 的步骤是把 KCM 插件装进系统路径；无构建工具的机器可
`./install.sh --skip-build` 跳过克隆与构建。

## 配置

配置文件：`~/.config/burn-window-randomrc`

```ini
[General]
Pool=kwin6_effect_aura_glow,kwin6_effect_doom,...   # 特效池（安装时从目录提取）
Blacklist=                                           # 被剔除的特效 id，逗号分隔
ApplyScript=/home/<你>/.local/libexec/burn-window-apply-config.sh
```

- 修改黑名单后重新应用（免 sudo、非交互）：`./install.sh --apply-config`
- 路径可用环境变量重定向：`BURN_WINDOW_CONFIG`（配置文件）、`BURN_WINDOW_EFFECTS`（特效目录）
- 图形界面：**系统设置 → 窗口管理 → 动效**，选中「随机特效 [Burn-My-Windows]」条目后点「配置…」；
  该 KCM 在 `kcm/kcm_burnwindow.json` 中注册于 `windowmanagement` 分类

### install.sh 参数

| 参数 | 作用 |
|------|------|
| `--apply-config` | 黑名单变更后重新注入并重载特效（免 sudo、非交互） |
| `--emit-apply-script` | 输出独立 apply 脚本内容（供安装时落盘） |
| `--prefix DIR` | 把所有写入路径重定向到 DIR 下（隔离测试用） |
| `--dry-run` | 只打印计划，不落盘 |
| `--skip-build` | 跳过克隆与构建 |
| `--skip-kwinrc` | 跳过写 kwinrc |
| `--skip-sudo` | 跳过需提权的 KCM 安装步骤 |
| `--fail-build` / `--fail-sudo` | 模拟构建/提权失败（验证失败即中止、不留半安装状态） |

## 卸载

```bash
./uninstall.sh          # 完整卸载，幂等（二次执行仍退出码 0）
./uninstall.sh --dry-run  # 只打印将要执行的清理计划
```

## 项目结构

```
install.sh                     # 安装入口（构建 → 注入 → kwinrc → KCM → 配置）
uninstall.sh                   # 卸载入口（10 步清理，幂等）
lib/arbiter.js                 # 仲裁核心：抽签决定 winner（整体注入 19 个特效）
lib/inject.py                  # 注入器：4 锚点改写 main.js，支持 --restore
placeholder/kwin6_effect_bmw_random/   # 占位特效（动效下拉条目 + 总开关载体）
kcm/                           # KCM 配置模块（Qt6/KF6 + QML）
  ├── CMakeLists.txt / kcm.cpp #   C++ 侧（KQuickConfigModule）
  ├── ui/main.qml              #   界面（列表、预览、参数、开关）
  └── po/zh_CN.po              #   中文翻译
upstream/                      # 上游 Burn-My-Windows 克隆（不入库，install.sh 按需拉取）
tests/                         # 8 个测试脚本 + fixtures
docs/superpowers/              # 设计文档（specs）与实现计划（plans）
```

## 测试

```bash
node tests/arbiter.test.mjs          # 随机仲裁单测
python3 -m pytest -q tests/test_inject.py   # 注入器测试
bash tests/test_install.sh           # 首装流程（--prefix 隔离，不触真实环境）
bash tests/test_uninstall.sh         # 卸载完整性（--prefix 隔离）
bash tests/test_apply_config.sh      # 黑名单应用链路
bash tests/test_kcm_build.sh         # KCM 构建/加载诊断（sudo 用例需先 sudo -v）
bash tests/test_kcm_qml.sh           # KCM QML 界面探针（需已真实安装）
bash tests/test_e2e.sh               # 端到端验收（需先真实安装）
```

## License

- 本仓库代码：**MIT**（见 [LICENSE](./LICENSE)）
- 上游 [Burn-My-Windows](https://github.com/Schneegans/Burn-My-Windows) 及其特效产物：**GPLv3**（构建时按上游 `LICENSE` 获取）
- 占位特效 `metadata.json` 声明 `License: GPLv3`（与上游特效一致）
