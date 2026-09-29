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

    // [{effectId: string, displayName: string}] —— displayName 取自特效 metadata.json
    Q_PROPERTY(QVariantList pool READ pool CONSTANT)
    // 当前黑名单（勾选即入黑名单 = 不参与随机）
    Q_PROPERTY(QStringList blacklist READ blacklist NOTIFY blacklistChanged)
    // 最近一次 apply 的结果描述（成功为脚本输出，失败为失败原因）
    Q_PROPERTY(QString applyOutput READ applyOutput NOTIFY applyOutputChanged)
    // apply 进行中 —— QML 用它禁用 Apply 按钮
    Q_PROPERTY(bool applyRunning READ applyRunning NOTIFY applyRunningChanged)

public:
    explicit BurnWindowKCM(QObject *parent, const KPluginMetaData &metaData);

    QVariantList pool() const { return m_pool; }
    QStringList blacklist() const { return m_blacklist; }
    QString applyOutput() const { return m_applyOutput; }
    bool applyRunning() const { return m_applyRunning; }

    // 把某特效加入(add=true)或移出(add=false)黑名单；改内存态并置 modified，
    // 由 QML 的 Apply 触发 apply() 才持久化并重新注入。
    Q_INVOKABLE void toggleBlacklist(const QString &effectId, bool add);

    // 持久化黑名单并执行 ApplyScript；完成后恢复按钮可用状态。
    // 任何失败都把原因写入 applyOutput，不抛异常、不挂起。
    Q_INVOKABLE void apply();

    // 框架在用户点击 Apply/Ok 时调用的入口（KAbstractConfigModule::save()，
    // 见 kabstractconfigmodule.h:272-274 注释）。必须接到 apply()，
    // 否则 KCM 的 Apply 按钮点击后无任何反应。
    void save() override;

Q_SIGNALS:
    void blacklistChanged();
    void applyOutputChanged();
    void applyRunningChanged();

private:
    void loadConfig();
    void saveBlacklist();
    void finishApply(bool ok);
    QString effectDisplayName(const QString &effectId) const;

    QVariantList m_pool;
    QStringList m_blacklist;
    QString m_applyOutput;
    bool m_applyRunning = false;

    QString m_configPath;
    QString m_applyScript;
    QString m_effectsDir;
};
