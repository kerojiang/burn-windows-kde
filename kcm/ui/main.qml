import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kcmutils as KCMUtils

// 黑名单勾选界面。
//
// 勾选语义（需求方向，不可反）：勾选 = 加入黑名单 = 不参与随机；
// 未勾选 = 参与随机。默认 19 项全部不勾选。
// 状态一律由 kcm.blacklist 驱动（单向绑定），用户交互只调用 toggleBlacklist。
KCMUtils.SimpleKCM {
    title: i18n("Burn Window")

    ColumnLayout {
        width: parent.width
        spacing: 8

        QQC2.Label {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: i18n("勾选的特效将被剔除，不参与窗口打开与关闭的随机选择；未勾选的特效才会参与抽签。默认全部不勾选，即所有已安装特效都参与随机。")
        }

        Repeater {
            model: kcm.pool

            delegate: QQC2.CheckBox {
                id: effectCheck
                required property var modelData

                Layout.fillWidth: true
                text: modelData.displayName

                // 单向绑定：界面永远反映 kcm.blacklist 的当前内容
                checked: kcm.blacklist.includes(modelData.effectId)

                // 用 clicked 而非 toggled —— toggled 在程序化赋值 checked 时
                // 同样发出，会把初始化的绑定结果反写回黑名单
                onClicked: kcm.toggleBlacklist(modelData.effectId, checked)

                Component.onCompleted: {
                    // 诊断探针：渲染与绑定结果写入 journal，供无 GUI 环境断言
                    console.log("BMW_KCM_ITEM " + modelData.effectId + " checked=" + checked)
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
    }
}
