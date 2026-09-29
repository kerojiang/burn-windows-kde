cmake_minimum_required(VERSION 3.20)
project(burnwindowkcm)

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
    Qt6::Core
    Qt6::Gui
    Qt6::Qml
)
