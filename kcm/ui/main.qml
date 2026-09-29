import QtQuick
import org.kde.kcmutils as KCMUtils

// 占位：kcmutils_add_qml_kcm 要求 ui/main.qml 存在，否则配置阶段 FATAL_ERROR。
// 完整的黑名单勾选界面在 Task 6 实现 —— 届时本文件会被替换。
KCMUtils.SimpleKCM {
    title: i18n("Burn Window")
}
