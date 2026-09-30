import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kcmutils as KCMUtils
import org.kde.kquickcontrols as KQuickControls

// 随机特效聚合页（D1-D7）。
//
// 参与语义（D3，不可反）：勾选 = 参与随机；取消勾选 = 剔除。默认 19 项全部勾选。
// 状态由 kcm.blacklist 驱动（带 NOTIFY blacklistChanged；2026-09-30 起
// checked 绑定它而非 pool 的 participating —— 后者是 loadConfig 的一次性
// 快照，全选按钮程序化批量改 19 项时不会触发它更新，界面不刷新）。
// 写入口仍是 C++ 侧的参与语义反转映射（kcm.toggleParticipating）。
// 开关（D4/D6）：只读徽标展示 kcm.randomLoaded（唯一真相源是 KWin
// loadedEffects），页面不提供任何 toggle，操作回归特效页的占位特效。
KCMUtils.SimpleKCM {
    id: burnRoot
    title: i18n("Burn Window")
    // 页面高度固定 ~900（2026-09-30 批准的需求4设计）：不 fill 视口（fill 时
    // page=1319、收起内容 854 → 底部 446 空白）。900 = 854 + 余量 46，展开
    // 参数超出 → 页内滚动；若被容器锚定覆盖则切备选（解除锚定后设高）。
    height: 900
    // 容器（kcmshell6/systemsettings）布局时显式 setHeight(视口高)，会断开
    // QML 静态绑定 —— 实测锚定已解除、Layout 约束已设，onCompleted 时
    // h=900 但下一帧仍被改回 1319。用 onHeightChanged 拦截拉回：容器设高
    // → 本 handler 延一拍设回 900；900 自身的变化被 if 挡住不递归。
    // height 拦截机制的运行证据：容器每次 setHeight(视口) → 这里打一条 →
    // callLater 拉回 900。启动收敛序列（实测）：-46→852→1319→900→1318→
    // 1300→900。日后若"页面又变高"，看此序列即可判断是容器设的还是拦截失效。
    onHeightChanged: {
        console.log("BMW_KCM_HSEQ h=" + height)
        if (height !== 900) {
            Qt.callLater(function () { burnRoot.height = 900 })
        }
    }
    // 容器若用 Layout 管理，这两个与 height: 900 一起才锁得住；
    // 非 Layout 管理时被忽略，无副作用。
    Layout.fillHeight: false
    Layout.minimumHeight: 900
    Layout.maximumHeight: 900

    // 初始 GEOM 探针：延 500ms 等 height 收敛（见 onHeightChanged 的 HSEQ）
    Timer {
        id: initialGeomTimer
        interval: 500
        repeat: false
        onTriggered: rootColumn.dumpGeom("initial")
    }

    // Color 参数双格式归一（Ruling-10）：kwinrc 现值的 "r,g,b" 十进制 → #RRGGBB；
    // #hex（main.xml default 的 #AARRGGBB、KWin 现值的 #RRGGBB）原样返回。
    // 返回值直接喂 ColorButton.color（Qt 的 color 类型接受 #RGB/#RRGGBB/#AARRGGBB）。
    function toDisplayColor(v) {
        if (!v) {
            return "#000000"
        }
        var s = String(v)
        if (s.charAt(0) === "#") {
            return s
        }
        var m = s.match(/^\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})/)
        if (m) {
            var hex = function (c) {
                return ("0" + Number(c).toString(16)).slice(-2)
            }
            return "#" + hex(m[1]) + hex(m[2]) + hex(m[3])
        }
        return s
    }

    ColumnLayout {
        id: rootColumn
        width: parent.width
        spacing: 8

        // 高度几何探针（需求4诊断）：现象「内容不多但页面被撑高」。
        // SimpleKCM = Kirigami.ScrollablePage（自带滚动，源码 SimpleKCM.qml:37），
        // 故根因不在"缺滚动"，需实测各层高度定位谁撑高。
        // 用 Qt.callLater —— ScrollablePage 的 flickable/anchors 在其自身
        // Component.onCompleted 才装配（ScrollablePage.qml:324-368），
        // 子项 onCompleted 早于父项，直接读会拿到装配前的值。
        // dumpGeom(tag) 可复用：初始一次 + 每次展开/收起参数面板各一次，
        // tag 区分状态（initial / toggle:<id>:<visible>），用于判断
        // "内容超高时 page 是否收缩/是否出现滚动"。
        function dumpGeom(tag) {
            var fl = burnRoot.flickable
            console.log("BMW_KCM_GEOM " + tag
                      + " page=" + burnRoot.height
                      + " implicitPage=" + burnRoot.implicitHeight
                      + " contentH=" + burnRoot.contentHeight
                      + " viewport=" + (fl ? fl.height : -1)
                      + " col=" + rootColumn.height
                      + " colImplicit=" + rootColumn.implicitHeight
                      + " n=" + rootColumn.children.length)
        }

        // 预览窗口保持时长 = 该特效 Duration（params 由 parseMainXml 带出，
        // 含 kwinrc 现值与 main.xml 默认值），缺失或非法回落 1500ms。
        // 保持这么久是为了让 open 动画播完，随后 close() 触发 close 动画。
        function previewDuration(params) {
            for (var i = 0; i < params.length; i++) {
                if (params[i].name === "Duration") {
                    var v = Number(params[i].value)
                    if (!isNaN(v) && v > 0) {
                        return v
                    }
                }
            }
            return 1500
        }

        // 临时预览窗口：真实顶层 toplevel —— ApplicationWindow 默认不带
        // Qt.Popup flags，normalWindow=true，因此不会被 main.js:186-218 的
        // hasDecoration/popupWindow/classBlacklist 判定过滤掉（若用 Popup flags
        // 会变 XdgPopupWindow → normalWindow=false → 窗口开了也不播动画）。
        // title 由预览按钮写入 "BMW_PREVIEW:<effectId>"，注入到特效的
        // lib/arbiter.js bmwPreviewTarget 识别后强制该特效当选 ——
        // KWin 无 playEffect/previewEffect API（spec §8 决策记录调研实证）。
        QQC2.ApplicationWindow {
            id: previewWindow
            visible: false
            width: 520
            height: 360
            title: ""
        }

        // 到点关闭预览窗口 → 触发 close 动画
        Timer {
            id: previewCloseTimer
            repeat: false
            onTriggered: previewWindow.close()
        }

        // "initial" 探针已移至 burnRoot 的 Component.onCompleted（解容器
        // 垂直锚定之后）—— 子项 onCompleted 早于父项，留在这里会读到锚定
        // 解除前的 page（实测 1319 而非 900）。toggle: 探针仍在齿轮 onClicked。

        QQC2.Label {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: i18n("勾选的特效参与窗口打开与关闭的随机选择；取消勾选则剔除。默认全部勾选。")
        }

        RowLayout {
            id: badgeRow
            Layout.fillWidth: true

            // 全选判定：黑名单 ∩ pool = ∅。黑名单可能含池外历史残留（从 kwinrc
            // 读入），故逐个核对池内成员而非直接看 blacklist.length。
            readonly property bool allSelected: {
                for (var i = 0; i < kcm.pool.length; i++) {
                    if (kcm.blacklist.indexOf(kcm.pool[i].effectId) !== -1) {
                        return false
                    }
                }
                return true
            }

            // 开关只读徽标（D6）：只展示不操作；文案用字面量而非 i18n，
            // 使无 GUI 环境的探针断言不依赖翻译环境
            QQC2.Label {
                font.bold: true
                text: kcm.randomLoaded ? "随机特效：已启用" : "随机特效：未启用"
                Component.onCompleted: {
                    console.log("BMW_KCM_SWITCH_BADGE=" + (kcm.randomLoaded ? "已启用" : "未启用"))
                }
            }

            Item { Layout.fillWidth: true }   // 撑开空间，让按钮靠右

            // 全选/全不选：单个切换按钮，文案随状态自适应。
            // 执行走既有 toggleParticipating 循环（D3 反转映射在 C++ 完成），
            // 只改内存 m_blacklist，仍由 apply() 落盘 —— 与单个勾选同一路径，
            // 不新增落盘时机。点击后界面刷新依赖 checked 绑定 kcm.blacklist
            // （见下方 CheckBox 注释），不是这里显式去改 19 个勾选框。
            QQC2.Button {
                id: selectAllButton
                text: badgeRow.allSelected ? i18n("全不选") : i18n("全选")
                onClicked: {
                    var target = !badgeRow.allSelected
                    for (var i = 0; i < kcm.pool.length; i++) {
                        kcm.toggleParticipating(kcm.pool[i].effectId, target)
                    }
                    // 点击探针：blacklistNow 供手动验收断言
                    //（空 = 全选已写入；19 项 = 全不选已写入）
                    console.log("BMW_KCM_SELECT_ALL clicked target=" + target
                              + " blacklistNow=" + kcm.blacklist.join(","))
                }
                Component.onCompleted: {
                    console.log("BMW_KCM_SELECT_ALL initial allSelected=" + badgeRow.allSelected
                              + " text=" + text)
                }
            }
        }

        Repeater {
            model: kcm.pool

            delegate: ColumnLayout {
                id: effectRoot
                required property var modelData
                Layout.fillWidth: true
                spacing: 2

                RowLayout {
                    Layout.fillWidth: true

                    QQC2.CheckBox {
                        id: effectCheck
                        Layout.fillWidth: true
                        text: effectRoot.modelData.displayName

                        // 参与语义 = 不在黑名单（与 kcm.cpp:126 的 !contains 同义，
                        // 初始值与探针断言均不受影响）。
                        // 绑 kcm.blacklist（带 NOTIFY blacklistChanged）而非
                        // modelData.participating：后者是 pool(CONSTANT) 在
                        // loadConfig 算好的一次性快照（kcm.h:26 + kcm.cpp:115-131），
                        // toggleBlacklist 只改 m_blacklist 不重建 pool → 单个勾选
                        // 能显示全靠用户点击本身改变了控件状态，而全选按钮的
                        // 程序化批量改 19 项时绑定源纹丝不动 → 界面不刷新。
                        // 绑定 blacklist 后两者都由 blacklistChanged 驱动重算。
                        checked: kcm.blacklist.indexOf(effectRoot.modelData.effectId) === -1

                        // 用 clicked 而非 toggled —— toggled 在程序化赋值 checked 时
                        // 同样发出，会把初始化的绑定结果反写回模型
                        onClicked: kcm.toggleParticipating(effectRoot.modelData.effectId, checked)

                        Component.onCompleted: {
                            // 诊断探针：渲染与参与语义写入 journal，供无 GUI 环境断言
                            console.log("BMW_KCM_ITEM " + effectRoot.modelData.effectId + " checked=" + checked)
                            console.log("BMW_KCM_PARTICIPATING " + effectRoot.modelData.effectId + "=" + checked)
                        }
                    }

                    // 预览按钮：点开临时窗口播一次该特效后自动关闭。
                    // 图标 media-playback-start（breeze 图标主题实测存在）；
                    // tooltip 走 ToolTip attached property —— ToolButton 没有
                    // tooltip 属性（2026-09-30 实测写 tooltip.text 会
                    // "Cannot assign to non-existent property" 打挂整个 QML）。
                    QQC2.ToolButton {
                        id: previewButton
                        icon.name: "media-playback-start"
                        QQC2.ToolTip.visible: hovered
                        QQC2.ToolTip.text: i18n("预览此特效")
                        QQC2.ToolTip.delay: 500
                        onClicked: {
                            previewWindow.title = "BMW_PREVIEW:" + effectRoot.modelData.effectId
                            previewCloseTimer.interval = rootColumn.previewDuration(effectRoot.modelData.params)
                            previewWindow.show()
                            previewCloseTimer.restart()
                        }
                        Component.onCompleted: {
                            // 探针：按钮形态与覆盖数进 journal，供无 GUI 断言
                            console.log("BMW_KCM_PREVIEW " + effectRoot.modelData.effectId
                                      + " icon=" + icon.name)
                        }
                    }

                    QQC2.ToolButton {
                        id: gearButton
                        visible: effectRoot.modelData.params.length > 0
                        // 纯图标 + tooltip：按钮本体不出现文字，说明文案走悬停提示。
                        // ToolButton 没有 tooltip 属性（Qt 源码 ToolButton.qml 与 qmldir
                        // 类型定义均无，2026-09-30 实证），写 tooltip.text 会
                        // "Cannot assign to non-existent property" 导致整个 QML 加载失败
                        // —— journal 实测原文见 main.qml:118。必须用 ToolTip attached
                        // property，KDE 先例 breeze/ItemDelegate.qml:32-33 同款写法。
                        icon.name: "settings-configure"
                        readonly property string tip: paramsColumn.visible ? i18n("收起参数") : i18n("设置参数")
                        QQC2.ToolTip.visible: hovered
                        QQC2.ToolTip.text: gearButton.tip
                        QQC2.ToolTip.delay: 500
                        onClicked: {
                            paramsColumn.visible = !paramsColumn.visible
                            // 展开/收起后立即打几何快照：判断内容超高时
                            // page 是否收缩到内容高度、滚动条是否出现
                            rootColumn.dumpGeom("toggle:" + effectRoot.modelData.effectId + ":" + paramsColumn.visible)
                        }

                        Component.onCompleted: {
                            // 诊断探针：图标名 + 可见性 + tooltip 文案进 journal，供无 GUI 断言
                            console.log("BMW_KCM_GEAR " + effectRoot.modelData.effectId
                                      + " icon=" + icon.name
                                      + " visible=" + visible
                                      + " tooltip=" + tip)
                        }
                    }
                }

                // 参数区（D7 自渲染）：初始收起；控件按 main.xml 的 type 分支。
                // visible:false 不阻止对象创建，参数探针照常输出。
                ColumnLayout {
                    id: paramsColumn
                    visible: false
                    Layout.fillWidth: true
                    Layout.leftMargin: 24
                    spacing: 2

                    Repeater {
                        model: effectRoot.modelData.params

                        delegate: RowLayout {
                            id: paramRow
                            required property var modelData
                            Layout.fillWidth: true

                            QQC2.Label {
                                Layout.preferredWidth: 160
                                elide: Text.ElideRight
                                text: paramRow.modelData.name
                            }

                            // 值域降级依据（P1-5）：spec 4.3 要求 min/max 来自
                            // main.xml 的 <min>/<max>，但上游 19 特效 main.xml 实测
                            // 无该标签（2026-09-29 全池 grep 0 文件）→ 无数据源，按
                            // 类型给固定兜底值域（UInt 非负 / Int 双向 / Double 双向，
                            // Double 负下限覆盖实测负默认 Tilt=-0.3、Shift=-0.05）。
                            // UInt：整数 [0, 65535]（全池实测最大 1500，留覆盖余量）
                            QQC2.SpinBox {
                                visible: paramRow.modelData.type === "UInt"
                                editable: true
                                from: 0
                                to: 65535
                                value: Number(paramRow.modelData.value) || 0
                                onValueModified: kcm.setParam(effectRoot.modelData.effectId, paramRow.modelData.name, String(value))
                            }

                            // Int：有符号整数（spec 4.3 Int → SpinBox）
                            QQC2.SpinBox {
                                visible: paramRow.modelData.type === "Int"
                                editable: true
                                from: -32768
                                to: 32767
                                value: Number(paramRow.modelData.value) || 0
                                onValueModified: kcm.setParam(effectRoot.modelData.effectId, paramRow.modelData.name, String(value))
                            }

                            // Double：Qt 6.11 专用 DoubleSpinBox（decimals=2 stepSize=0.01）
                            // from 必须允许负值 —— from: 0 会把 Tilt/Shift 的负默认钳为 0，
                            // onValueModified 触发即写回 0 覆盖负值（reviewer P1-5）
                            QQC2.DoubleSpinBox {
                                visible: paramRow.modelData.type === "Double"
                                editable: true
                                from: -1000
                                to: 1000
                                decimals: 2
                                stepSize: 0.01
                                value: Number(paramRow.modelData.value) || 0
                                onValueModified: kcm.setParam(effectRoot.modelData.effectId, paramRow.modelData.name, String(value))
                            }

                            // String：自由文本（spec 4.3 String → TextField）
                            QQC2.TextField {
                                visible: paramRow.modelData.type === "String"
                                text: String(paramRow.modelData.value)
                                onEditingFinished: kcm.setParam(effectRoot.modelData.effectId, paramRow.modelData.name, text)
                            }

                            // Bool
                            QQC2.CheckBox {
                                visible: paramRow.modelData.type === "Bool"
                                checked: String(paramRow.modelData.value).toLowerCase() === "true"
                                onToggled: kcm.setParam(effectRoot.modelData.effectId, paramRow.modelData.name, String(checked))
                            }

                            // Color：展示归一后喂入，回写 Qt 标准 #hex（Ruling-10）
                            KQuickControls.ColorButton {
                                visible: paramRow.modelData.type === "Color"
                                color: burnRoot.toDisplayColor(paramRow.modelData.value)
                                onAccepted: (selectedColor) => kcm.setParam(effectRoot.modelData.effectId, paramRow.modelData.name, selectedColor.toString())
                            }

                            Item {
                                Layout.fillWidth: true
                            }

                            Component.onCompleted: {
                                console.log("BMW_KCM_PARAM_WIDGET " + effectRoot.modelData.effectId + " " + paramRow.modelData.name + " " + paramRow.modelData.type)
                                console.log("BMW_KCM_PARAM_EDIT " + effectRoot.modelData.effectId + " " + paramRow.modelData.name + "=" + paramRow.modelData.value)
                            }
                        }
                    }
                }
            }
        }

        // apply 结果（成功为脚本输出，失败为失败原因）——错误必须对用户可见
        QQC2.Label {
            Layout.fillWidth: true
            visible: kcm.applyOutput.length > 0
            wrapMode: Text.WordWrap
            text: kcm.applyOutput
        }
    }

    Component.onCompleted: {
        // 备选方案（2026-09-30 实测：静态 height: 900 被容器锚定覆盖，
        // GEOM initial page=1319 不变）：解除容器对本页的垂直锚定 ——
        // anchors.fill 组合的 top/bottom 拆掉，left/right 保留 → 宽度仍
        // 随窗口变化，高度交还给静态 height: 900。随后（事件循环下一拍、
        // 布局重算后）再打 initial 探针。
        anchors.top = undefined
        anchors.bottom = undefined
        // 初始探针延到布局收敛后：容器 setHeight(视口) 与 onHeightChanged
        // 拦截拉回要数拍才稳（HSEQ 实测 -46→852→1319→900→1318→1300→900），
        // 同步 callLater 打到的是中间态 1319。500ms 后稳定值是 900。
        initialGeomTimer.start()
        // 诊断探针：证明 QML 已加载，并主动输出自身 QRC 路径。
        // 不依赖 Qt 的日志格式 —— 实测 Qt6 的 console.log 写入 journal 时
        // 不带源路径前缀，无法从日志中反推文件位置。
        console.log("BMW_KCM_QML_LOADED")
        console.log("BMW_KCM_QML_URL=" + Qt.resolvedUrl("main.qml"))
        // 状态探针：证明 QML 侧确实读取 kcm.applyRunning（该属性此前在
        // main.qml 中零命中，属死属性），值进 journal 供无 GUI 环境断言
        console.log("BMW_KCM_APPLY_RUNNING=" + kcm.applyRunning)
    }
}
