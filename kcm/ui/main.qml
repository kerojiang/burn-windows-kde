import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kcmutils as KCMUtils
import org.kde.kquickcontrols as KQuickControls

// 随机特效聚合页（D1-D7）。
//
// 参与语义（D3，不可反）：勾选 = 参与随机；取消勾选 = 剔除。默认 19 项全部勾选。
// 状态由 kcm.pool 的 participating 驱动 —— 黑名单反转映射在 C++ 侧完成，
// 本页只操作参与语义（kcm.toggleParticipating）。
// 开关（D4/D6）：只读徽标展示 kcm.randomLoaded（唯一真相源是 KWin
// loadedEffects），页面不提供任何 toggle，操作回归特效页的占位特效。
KCMUtils.SimpleKCM {
    id: burnRoot
    title: i18n("Burn Window")

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
        width: parent.width
        spacing: 8

        QQC2.Label {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: i18n("勾选的特效参与窗口打开与关闭的随机选择；取消勾选则剔除。默认全部勾选。")
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

                        // 单向绑定：界面永远反映参与语义的当前状态
                        checked: effectRoot.modelData.participating

                        // 用 clicked 而非 toggled —— toggled 在程序化赋值 checked 时
                        // 同样发出，会把初始化的绑定结果反写回模型
                        onClicked: kcm.toggleParticipating(effectRoot.modelData.effectId, checked)

                        Component.onCompleted: {
                            // 诊断探针：渲染与参与语义写入 journal，供无 GUI 环境断言
                            console.log("BMW_KCM_ITEM " + effectRoot.modelData.effectId + " checked=" + checked)
                            console.log("BMW_KCM_PARTICIPATING " + effectRoot.modelData.effectId + "=" + checked)
                        }
                    }

                    QQC2.Button {
                        visible: effectRoot.modelData.params.length > 0
                        text: paramsColumn.visible ? "参数 ▾" : "参数 ▸"
                        onClicked: paramsColumn.visible = !paramsColumn.visible
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
