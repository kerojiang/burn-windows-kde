cmake_minimum_required(VERSION 3.20)
# project 名 = KCM pluginId（kcm_burnwindow）：ki18n_install 按 PROJECT_NAME
# 决定编译产物 mo 名，须与 kcmutils 的 setTranslationDomain(pluginId) 对齐，
# 否则 cmake --install 装出的 mo 与 QML i18n 查询的 catalog 名不一致。
project(kcm_burnwindow)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(ECM 6.0.0 REQUIRED NO_MODULE)
set(CMAKE_MODULE_PATH ${ECM_MODULE_PATH} ${ECM_KDE_MODULE_PATH})

# 顺序要求（spec 4.8）：必须先创建 Qt6::Core target，KDEInstallDirs6 内部的
# QtVersionOption 才能识别 QT_MAJOR_VERSION=6（否则默认按 Qt5 查 qmake）。
find_package(Qt6 REQUIRED COMPONENTS Core Gui Qml Quick)

include(KDEInstallDirs6)
include(KDECMakeSettings)

find_package(KF6 REQUIRED COMPONENTS KCMUtils CoreAddons I18n Config)

# ui/main.qml 必须存在，否则此宏 FATAL_ERROR（spec 4.7 实测）
kcmutils_add_qml_kcm(kcm_burnwindow
    SOURCES kcm.cpp
)

target_link_libraries(kcm_burnwindow PRIVATE
    KF6::KCMUtilsQuick
    KF6::KCMUtilsCore
    KF6::CoreAddons
    KF6::ConfigCore   # KConfig / KConfigGroup
    KF6::I18n         # KLocalizedString（setApplicationDomain 翻译域注册）
    Qt6::Core
    Qt6::Gui
    Qt6::Qml
)

# i18n（2026-09-30）：po 编译安装（kcm_burnwindow.mo → share/locale）。本项目的
# KCM so 走 install.sh 手动 install（不经 cmake --install），.mo 由 install.sh
# 直接 msgfmt 落 ~/.local/share/locale；此处保留标准规则以兼容 cmake --install。
ki18n_install(kcm/po)
