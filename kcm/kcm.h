#pragma once

#include <KQuickConfigModule>
#include <QStringList>
#include <QVariantList>

#include <KPluginMetaData>

// 随机特效黑名单配置模块。
//
// 职责边界：QML 只通过本类暴露的属性/方法工作，不直接读 KConfig ——
// 配置的读写、黑名单持久化、apply 子进程管理全部收敛在 C++ 侧。
//
// 注意：KQuickConfigModule 的构造函数是 protected，不能用
// `using KQuickConfigModule::KQuickConfigModule;` 继承（会保持 protected，
// 导致 K_PLUGIN_FACTORY_WITH_JSON 的 registerPlugin<T>() 模板推导失败）。
// 必须在 public 区显式转发构造（spec 4.6 实测）。
class BurnWindowKCM : public KQuickConfigModule
{
    Q_OBJECT

    // [{effectId: string, displayName: string, participating: bool,
    //   params: [{name, type, default, value}]}]
    // participating = 未在黑名单（D3：勾上=参与，反转映射在 C++ 侧完成）；
    // params 来自各特效 contents/config/main.xml 的自渲染参数模型（D7）。
    Q_PROPERTY(QVariantList pool READ pool CONSTANT)
    // 当前黑名单（未勾选集合）
    Q_PROPERTY(QStringList blacklist READ blacklist NOTIFY blacklistChanged)
    // 开关只读状态：占位特效 ∈ KWin loadedEffects（D4/D6：唯一真相源是 KDE，
    // 聚合页只展示不自建开关）
    Q_PROPERTY(bool randomLoaded READ randomLoaded NOTIFY randomLoadedChanged)
    // 最近一次 apply 的结果描述（成功为脚本输出，失败为失败原因）
    Q_PROPERTY(QString applyOutput READ applyOutput NOTIFY applyOutputChanged)
    // apply 进行中 —— 实际消费者：apply() 的幂等闸（重复点击不启动第二个
    // 子进程）、main.qml 的状态探针、BMW_KCM_DIAG_APPLY_* 诊断输出。
    // 注意：框架 Apply 按钮的可用性由基类 needsSave 驱动，不读本属性。
    Q_PROPERTY(bool applyRunning READ applyRunning NOTIFY applyRunningChanged)

public:
    explicit BurnWindowKCM(QObject *parent, const KPluginMetaData &metaData);

    QVariantList pool() const { return m_pool; }
    QStringList blacklist() const { return m_blacklist; }
    bool randomLoaded() const { return m_randomLoaded; }
    QString applyOutput() const { return m_applyOutput; }
    bool applyRunning() const { return m_applyRunning; }

    // 把某特效加入(add=true)或移出(add=false)黑名单；改内存态并置 modified，
    // 由 QML 的 Apply 触发 apply() 才持久化并重新注入。
    Q_INVOKABLE void toggleBlacklist(const QString &effectId, bool add);

    // 参与语义入口（D3 反转映射）：participating=true → 移出黑名单，
    // false → 加入黑名单。QML 勾选框只调本方法，不直接操心黑名单方向。
    Q_INVOKABLE void toggleParticipating(const QString &effectId, bool participating);

    // 参数编辑（D7 自渲染）：只写内存脏区 m_paramDirty 并置 needsSave；
    // 落盘 kwinrc [Effect-<id>] 与 reconfigureEffect 统一在 apply() 完成。
    Q_INVOKABLE void setParam(const QString &effectId, const QString &name, const QString &value);

    // 持久化黑名单并执行 ApplyScript；完成后恢复按钮可用状态。
    // 任何失败都把原因写入 applyOutput，不抛异常、不挂起。
    Q_INVOKABLE void apply();

    // 框架在用户点击 Apply/Ok 时调用的入口（KAbstractConfigModule::save()，
    // 见 kabstractconfigmodule.h:272-274 注释）。必须接到 apply()，
    // 否则 KCM 的 Apply 按钮点击后无任何反应。
    void save() override;

Q_SIGNALS:
    void blacklistChanged();
    void randomLoadedChanged();
    void applyOutputChanged();
    void applyRunningChanged();

private:
    void loadConfig();
    void saveBlacklist();
    void finishApply(bool ok);
    QString effectDisplayName(const QString &effectId) const;
    // 解析特效参数模型 main.xml（KConfigXT：entry name/type + 子元素 default）。
    // 无文件 → 空表；XML 病态 → stderr 警告 + 空表（不崩溃、不影响其他成员）。
    QVariantList parseMainXml(const QString &effectId) const;
    // kwinrc 路径：BMW_KCM_KWINRC 环境变量覆盖（测试隔离），默认 ~/.config/kwinrc
    QString kwinrcPath() const;
    // 读 kwinrc [Effect-<effectId>] 的参数当前值，缺失回落 default
    QString currentParamValue(const QString &effectId, const QString &name, const QString &defaultValue) const;

    QVariantList m_pool;
    QStringList m_blacklist;
    bool m_randomLoaded = false;
    // qdbus6 loadedEffects 查询只跑一次（loadConfig 会被基类重复调用）
    bool m_randomLoadedQueryDone = false;
    // 参数脏区：[{effectId, name, value}]，apply() 成功后清空
    QVariantList m_paramDirty;
    QString m_applyOutput;
    bool m_applyRunning = false;

    QString m_configPath;
    QString m_applyScript;
    QString m_effectsDir;
};
