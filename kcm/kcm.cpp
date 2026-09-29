#include "kcm.h"

#include <KConfig>
#include <KConfigGroup>
#include <KPluginFactory>

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocale>
#include <QProcess>
#include <QTimer>

#include <cstdio>

BurnWindowKCM::BurnWindowKCM(QObject *parent, const KPluginMetaData &metaData)
    : KQuickConfigModule(parent, metaData)
{
    // 本模块只提供 Apply：黑名单的持久化与重新注入都由 apply() 完成，
    // 不提供 Default（spec 未要求恢复默认行为，避免界面上出现无实现的按钮）。
    setButtons(Apply);

    loadConfig();

    // 诊断开关：KCM 加载后自动执行一次 apply，把结果写到 stderr 再退出。
    // 用途是在无 GUI 交互的环境下验证 apply 链路（KCM 的 console 输出会进 journal）。
    // 正常使用时不设置该变量，行为与未添加此分支一致。
    if (qEnvironmentVariableIsSet("BMW_KCM_DIAG_APPLY")) {
        QTimer::singleShot(0, this, [this]() {
            // 走 save() 而非直接 apply()：与 Apply 按钮同一入口，
            // 使该诊断同时验证 save()→apply() 已接通
            save();
            std::fprintf(stderr, "BMW_KCM_DIAG_APPLY_OUTPUT=%s\n", qPrintable(m_applyOutput));
            std::fflush(stderr);
            QCoreApplication::exit(0);
        });
    }
}

// 配置路径与特效目录都遵循 apply 脚本同一套环境变量约定，
// 测试可用前缀目录隔离，不污染 ~/.config。
void BurnWindowKCM::loadConfig()
{
    m_configPath = qEnvironmentVariable("BURN_WINDOW_CONFIG");
    if (m_configPath.isEmpty()) {
        m_configPath = QDir::homePath() + QStringLiteral("/.config/burn-window-randomrc");
    }
    m_effectsDir = qEnvironmentVariable("BURN_WINDOW_EFFECTS");
    if (m_effectsDir.isEmpty()) {
        m_effectsDir = QDir::homePath() + QStringLiteral("/.local/share/kwin/effects");
    }

    KConfig cfg(m_configPath, KConfig::SimpleConfig);
    KConfigGroup group(&cfg, QStringLiteral("General"));

    const QString poolCsv = group.readEntry("Pool", QString());
    const QString blacklistCsv = group.readEntry("Blacklist", QString());
    m_applyScript = group.readEntry("ApplyScript", QString());

    m_pool.clear();
    const QStringList poolIds = poolCsv.split(QLatin1Char(','), Qt::SkipEmptyParts);
    for (const QString &effectId : poolIds) {
        QVariantMap item;
        item.insert(QStringLiteral("effectId"), effectId);
        item.insert(QStringLiteral("displayName"), effectDisplayName(effectId));
        m_pool.append(item);
    }

    m_blacklist = blacklistCsv.split(QLatin1Char(','), Qt::SkipEmptyParts);
}

// 显示名取自特效自身的 metadata.json：KConfig 里只存 ID，不重复保存显示名，
// 避免两份数据不一致。读不到时回退到 effectId，保证 UI 不出现空行。
QString BurnWindowKCM::effectDisplayName(const QString &effectId) const
{
    QFile file(m_effectsDir + QLatin1Char('/') + effectId + QStringLiteral("/metadata.json"));
    if (!file.open(QIODevice::ReadOnly)) {
        return effectId;
    }

    const QJsonObject kplugin =
        QJsonDocument::fromJson(file.readAll()).object().value(QStringLiteral("KPlugin")).toObject();

    const QString locale = QLocale::system().name(); // 例如 zh_CN
    QString name = kplugin.value(QStringLiteral("Name[%1]").arg(locale)).toString();
    if (name.isEmpty()) {
        name = kplugin.value(QStringLiteral("Name[%1]").arg(locale.left(2))).toString(); // zh
    }
    if (name.isEmpty()) {
        name = kplugin.value(QStringLiteral("Name")).toString();
    }
    return name.isEmpty() ? effectId : name;
}

void BurnWindowKCM::toggleBlacklist(const QString &effectId, bool add)
{
    if (add) {
        if (!m_blacklist.contains(effectId)) {
            m_blacklist.append(effectId);
        }
    } else {
        m_blacklist.removeAll(effectId);
    }
    emit blacklistChanged();
    setNeedsSave(true);
}

// 黑名单只有在这里才落盘：勾选→内存态，Apply→持久化+重新注入。
void BurnWindowKCM::saveBlacklist()
{
    KConfig cfg(m_configPath, KConfig::SimpleConfig);
    KConfigGroup group(&cfg, QStringLiteral("General"));
    group.writeEntry("Blacklist", m_blacklist.join(QLatin1Char(',')));
    group.sync();
}

void BurnWindowKCM::apply()
{
    if (m_applyRunning) {
        return; // 幂等：重复点击不启动第二个子进程
    }

    saveBlacklist();

    m_applyRunning = true;
    m_applyOutput.clear();
    emit applyRunningChanged();
    emit applyOutputChanged();

    if (m_applyScript.isEmpty() || !QFile::exists(m_applyScript)) {
        m_applyOutput = tr("ApplyScript 不存在：%1")
                            .arg(m_applyScript.isEmpty() ? tr("（配置项 ApplyScript 为空）")
                                                         : m_applyScript);
        finishApply(false);
        return;
    }

    QProcess proc;
    proc.start(m_applyScript, QStringList());
    if (!proc.waitForStarted(5000)) {
        m_applyOutput = tr("无法启动 apply 脚本：%1").arg(proc.errorString());
        finishApply(false);
        return;
    }

    // 契约（spec 4.5）：waitForFinished 带 15000ms 超时，超时杀进程并报错，
    // 绝不无限等待 —— 否则 Apply 按钮会永久停在 running 状态。
    if (!proc.waitForFinished(15000)) {
        proc.kill();
        proc.waitForFinished(1000);
        m_applyOutput = tr("apply 执行超时（15 秒），已终止子进程");
        finishApply(false);
        return;
    }

    const QString stdoutText = QString::fromLocal8Bit(proc.readAllStandardOutput()).trimmed();
    const QString stderrText = QString::fromLocal8Bit(proc.readAllStandardError()).trimmed();
    const QString detail = stderrText.isEmpty() ? stdoutText : stderrText;

    const bool ok = proc.exitStatus() == QProcess::NormalExit && proc.exitCode() == 0;
    if (ok) {
        m_applyOutput = detail;
    } else {
        const QString code = proc.exitStatus() == QProcess::NormalExit
                                 ? QString::number(proc.exitCode())
                                 : tr("进程崩溃");
        m_applyOutput = detail.isEmpty() ? tr("apply 失败（退出码 %1）").arg(code)
                                         : tr("apply 失败（退出码 %1）：%2").arg(code, detail);
    }
    finishApply(ok);
}

// KCM 的 Apply/Ok 按钮入口。基类 save() 是空实现，不 override 则按钮无效果。
void BurnWindowKCM::save()
{
    apply();
}

// 每条 return 路径都必须经过这里：applyRunning 归零才能让 Apply 按钮恢复可用，
// 否则一次超时/启动失败会把按钮永久锁死。
// ok=false 时保持 needsSave=true —— 黑名单虽已写入配置但注入未生效，
// 必须让用户能再次点击 Apply 重试。
void BurnWindowKCM::finishApply(bool ok)
{
    m_applyRunning = false;
    emit applyRunningChanged();
    emit applyOutputChanged();
    if (ok) {
        setNeedsSave(false); // 已持久化且已重新注入生效
    }
}

K_PLUGIN_FACTORY_WITH_JSON(BurnWindowKCMFactory, "kcm_burnwindow.json",
                            registerPlugin<BurnWindowKCM>();)

// K_PLUGIN_FACTORY_WITH_JSON 展开含一个带 Q_OBJECT 的工厂类，AUTOMOC 要求显式
// 引入本文件的 moc 输出，否则构建报 "add #include kcm.moc" 并中止（spec 4.8 实测）。
#include "kcm.moc"
