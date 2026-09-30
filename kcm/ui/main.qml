import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import QtQuick.Window
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
    // 页面高度随窗口 fill —— 撤掉首轮的页面 900 拦截（2a19d61）：用户实际
    // 要的是系统设置窗口 900 左右（窗口实测 1347/1319），窗口设好后页面
    // fill 自然 ~910；继续锁页面反而会在窗口拖大时制造底部空白。

    // 系统设置窗口高度 ~900（需求4 第二轮，方案B根因修复）：宿主
    // QQuickWidget SizeViewToRootObject 按本页 implicitWidth/Height 调顶层
    // 窗口（Qt qquickwidget.cpp rootObjectSize 读 root 的 implicit*）——
    // 实测加载瞬间 rootColumn 子项 implicit 未收敛产生峰值 1365
    // （IMPLSEQ 序列 11→1365→884，主题/字体异步应用前的默认值），窗口被
    // 推到 1365 后不回收 → 钳到工作区 1347（全屏）。客户端直接 resize 被
    // Wayland 拒（实测 winH 恒 1347，BMW_KCM_WIN requested=950 无效）。
    // 封顶 900：稳态 884 不触发 min（零行为变化）；峰值 1365→900 → 窗口停
    // 900±；展开参数 1256→900 → 页内滚动（设计行为）。
    // +18 是实测三态稳定线性关系 burnRoot.implicit = colImpl + 18
    // （866→884 / 1347→1365 / 1238→1256；构成 = padding 12 + header 6，
    // 见 ScrollablePage.qml:233 的 contentHeight+topPadding+bottomPadding
    // +implicitHeaderHeight+spacing）。硬编码前有三态一致实测背书。
    implicitHeight: Math.min(rootColumn.implicitHeight + 18, 900)

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
            var win = Window.window
            // winH = 顶层窗口实际高度：page > winH 直接证明"窗口没真变矮"
            // （Qt 属性设了 950 但 compositor 未应用 resize 时会看到这种矛盾）
            // implWH = 本页 implicit 尺寸 —— SizeViewToRootObject 下宿主按它
            // 调窗口（实测对照：Scale 页 400x200、本页全屏 1347），定位谁在
            // 撑窗口看这里。
            console.log("BMW_KCM_GEOM " + tag
                      + " winWH=" + (win ? win.width + "x" + win.height : "-1")
                      + " implWH=" + burnRoot.implicitWidth + "x" + burnRoot.implicitHeight
                      + " winH=" + (win ? win.height : -1)
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
            text: i18n("Checked effects participate in the random choice for window open/close; uncheck to exclude. All are checked by default.")
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
                text: kcm.randomLoaded ? i18n("Random effects: Enabled") : i18n("Random effects: Disabled")
                Component.onCompleted: {
                    console.log("BMW_KCM_SWITCH_BADGE=" + (kcm.randomLoaded ? i18n("Enabled") : i18n("Disabled")))
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
                text: badgeRow.allSelected ? i18n("Deselect All") : i18n("Select All")
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
                        QQC2.ToolTip.text: i18n("Preview this effect")
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
                        readonly property string tip: paramsColumn.visible ? i18n("Hide parameters") : i18n("Configure parameters")
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
                                text: i18n(paramRow.modelData.name)
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
                                // i18n 标签探针：显示文本经 i18n 后的值（LANG=C=英文原文，zh=po 译文）
                                console.log("BMW_KCM_PARAM_LABEL " + effectRoot.modelData.effectId + " " + paramRow.modelData.name + " " + i18n(paramRow.modelData.name))
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

    // 内容隐含尺寸序列（诊断窗口 898→1365 跳涨：实测本页加载瞬间
    // rootColumn.implicitHeight 峰值 1347（→burnRoot 1365），宿主按峰值推
    // 窗口后不回收 → 钳到工作区 1347；稳态收敛 866（→884）。峰值 1347 =
    // 23 子项行高 53-77 的未收敛总和，稳态行高 ~33 —— 打 PEAK/STABLE 两态
    // 明细对比定位收敛前后差异元素）。
    onImplicitHeightChanged: {
        var tag = implicitHeight > 1000 ? "PEAK" : (implicitHeight > 800 ? "STABLE" : "")
        if (tag === "")
            return
        console.log("BMW_KCM_IMPLSEQ " + tag + " h=" + implicitHeight + " w=" + implicitWidth
                  + " colH=" + rootColumn.height + " colImpl=" + rootColumn.implicitHeight)
        for (var i = 0; i < rootColumn.children.length; i++) {
            var c = rootColumn.children[i]
            console.log("BMW_KCM_IMPLDET " + tag + " i=" + i
                      + " h=" + c.height + " implH=" + c.implicitHeight
                      + " vis=" + c.visible)
        }
    }

    // 窗口尺寸变化序列（诊断：systemsettings 按 KCM 内容调窗口 —— 实测
    // Scale 页 400x200、本页全屏 1347）。切 KCM 时看本序列即知窗口何时被
    // 谁撑大/缩小。
    Window.onHeightChanged: console.log("BMW_KCM_WINSEQ wh=" + Window.window.width + "x" + Window.window.height)
    Window.onWidthChanged: console.log("BMW_KCM_WINSEQ wh=" + Window.window.width + "x" + Window.window.height)

    Component.onCompleted: {
        // 窗口高度改由 implicitHeight 封顶驱动（宿主 SizeViewToRootObject
        // 按内容调窗），不再客户端 resize（Wayland 实测被拒）。初始 GEOM
        // 探针延 500ms 等布局收敛。
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
