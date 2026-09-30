#include "kcm.h"

#include <KConfig>
#include <KConfigGroup>
#include <KLocalizedString>
#include <KPluginFactory>

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocale>
#include <QProcess>
#include <QTimer>
#include <QXmlStreamReader>

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
            // 可选参数预设（Task 8）：BMW_KCM_DIAG_PARAMS=id:name:value,...
            // 先 setParam 进脏区，使 save()→apply() 的参数段被真实执行
            const QString diagParams = qEnvironmentVariable("BMW_KCM_DIAG_PARAMS");
            if (!diagParams.isEmpty()) {
                const QStringList items =
                    diagParams.split(QLatin1Char(','), Qt::SkipEmptyParts);
                for (const QString &item : items) {
                    const QStringList parts = item.split(QLatin1Char(':'));
                    if (parts.size() == 3) {
                        setParam(parts[0], parts[1], parts[2]);
                    }
                }
            }
            // 走 save() 而非直接 apply()：与 Apply 按钮同一入口，
            // 使该诊断同时验证 save()→apply() 已接通
            save();
            std::fprintf(stderr, "BMW_KCM_DIAG_APPLY_OUTPUT=%s\n", qPrintable(m_applyOutput));
            // RF5「按钮状态恢复」用诊断输出代替 GUI 操作：
            // applyRunning 必须已归零（finishApply 是唯一收口，走不到它就会
            // 永远停在 running）；needsSave 失败路径保持 true，使框架按钮
            // 仍可点击重试（按钮可用性由基类 needsSave 驱动）。
            std::fprintf(stderr, "BMW_KCM_DIAG_APPLY_RUNNING=%s\n",
                         m_applyRunning ? "true" : "false");
            std::fprintf(stderr, "BMW_KCM_DIAG_APPLY_NEEDSSAVE=%s\n",
                         needsSave() ? "true" : "false");
            std::fflush(stderr);
            QCoreApplication::exit(0);
        });
    }

    // 聚合模型诊断开关（Task 6）：输出 pool 模型 JSON / randomLoaded，
    // 演示 toggleParticipating 反转映射与 setParam 脏区后退出。
    // 演示只改内存态、不 save() 落盘，进程退出即丢弃，无副作用。
    if (qEnvironmentVariableIsSet("BMW_KCM_DIAG_POOL")) {
        QTimer::singleShot(0, this, [this]() {
            // 1) pool 模型：含 participating 与 params（main.xml 自渲染数据源）
            const QJsonDocument doc(QJsonArray::fromVariantList(m_pool));
            std::fprintf(stderr, "BMW_KCM_POOL_MODEL=%s\n", doc.toJson(QJsonDocument::Compact).constData());
            // 2) 开关只读状态（KWin loadedEffects 是否含占位特效）
            std::fprintf(stderr, "BMW_KCM_RANDOM_LOADED=%s\n", m_randomLoaded ? "true" : "false");
            // 3) 参与语义反转映射演示：先关一个成员（入黑名单），再开（出黑名单）
            if (!m_pool.isEmpty()) {
                const QString firstId = m_pool.first().toMap().value(QStringLiteral("effectId")).toString();
                toggleParticipating(firstId, false);
                std::fprintf(stderr, "BMW_KCM_DIAG_BLACKLIST_TOGGLED=%s\n", qPrintable(m_blacklist.join(QLatin1Char(','))));
                toggleParticipating(firstId, true);
                std::fprintf(stderr, "BMW_KCM_DIAG_BLACKLIST_RESTORED=%s\n", qPrintable(m_blacklist.join(QLatin1Char(','))));
            }
            // 4) 参数脏区：setParam upsert 后计数为 1（计数而非 needsSave，
            //    因为上面的 toggle 已经置过 needsSave，归因会被污染）
            if (!m_pool.isEmpty()) {
                const QString firstId = m_pool.first().toMap().value(QStringLiteral("effectId")).toString();
                setParam(firstId, QStringLiteral("Duration"), QStringLiteral("4242"));
            }
            std::fprintf(stderr, "BMW_KCM_PARAMS_DIRTY=%d\n", m_paramDirty.size());
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

    // 先解析黑名单：pool 循环里的 participating 依赖它（D3 反转映射）
    m_blacklist = blacklistCsv.split(QLatin1Char(','), Qt::SkipEmptyParts);

    m_pool.clear();
    const QStringList poolIds = poolCsv.split(QLatin1Char(','), Qt::SkipEmptyParts);
    for (const QString &effectId : poolIds) {
        QVariantMap item;
        item.insert(QStringLiteral("effectId"), effectId);
        item.insert(QStringLiteral("displayName"), effectDisplayName(effectId));
        // D3 参与语义：未在黑名单 = 参与。反转映射在 C++ 侧完成，
        // QML 勾选框只读写 participating，不直接操心黑名单方向。
        item.insert(QStringLiteral("participating"), !m_blacklist.contains(effectId));
        // D7 参数自渲染：数据源是特效自身 main.xml 的 entry 定义 + kwinrc 当前值
        item.insert(QStringLiteral("params"), parseMainXml(effectId));
        m_pool.append(item);
    }

    // 开关只读状态（D4/D6，唯一真相源是 KWin）：qdbus6 查 loadedEffects
    // 是否含占位特效。查询只执行一次（loadConfig 会被基类重复调用）。
    // 查询失败（KWin 未运行/qdbus6 缺失）→ false：特效没加载即开关关，语义正确。
    if (!m_randomLoadedQueryDone) {
        m_randomLoadedQueryDone = true;
        QProcess qdbus;
        qdbus.start(QStringLiteral("qdbus6"),
                    {QStringLiteral("org.kde.KWin"), QStringLiteral("/Effects"),
                     QStringLiteral("org.kde.kwin.Effects.loadedEffects")});
        if (qdbus.waitForFinished(3000) && qdbus.exitCode() == 0) {
            const QStringList loaded = QString::fromUtf8(qdbus.readAllStandardOutput())
                                           .split(QLatin1Char('\n'), Qt::SkipEmptyParts);
            // 占位 ID 与 lib/inject.py 的 PLACEHOLDER_ID、install.sh 的占位目录名保持一致
            m_randomLoaded = loaded.contains(QStringLiteral("kwin6_effect_bmw_random"));
        } else {
            m_randomLoaded = false;
        }
    }
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
    // zh_Hans 档（i18n 2026-09-30）：KDE 中文语言代码惯例是 zh_Hans 而非 zh，
    // metadata 键统一写 Name[zh_Hans] —— 缺此档则 zh_CN 环境直接落英文 Name。
    if (name.isEmpty() && locale.startsWith(QLatin1String("zh"))) {
        name = kplugin.value(QStringLiteral("Name[zh_Hans]")).toString();
    }
    if (name.isEmpty()) {
        name = kplugin.value(QStringLiteral("Name[%1]").arg(locale.left(2))).toString(); // zh
    }
    if (name.isEmpty()) {
        name = kplugin.value(QStringLiteral("Name")).toString();
    }
    return name.isEmpty() ? effectId : name;
}

// D7 参数模型：解析特效 contents/config/main.xml（KConfigXT 格式，
// 结构为 <entry name="X" type="UInt"><default>1500</default></entry>）。
// 无文件 → 空表（无参数特效属正常）；XML 病态 → stderr 警告 + 空表，
// 不崩溃、不影响同池其他成员的解析。
QVariantList BurnWindowKCM::parseMainXml(const QString &effectId) const
{
    QVariantList params;
    QFile file(m_effectsDir + QLatin1Char('/') + effectId + QStringLiteral("/contents/config/main.xml"));
    if (!file.open(QIODevice::ReadOnly)) {
        return params;
    }

    QXmlStreamReader xml(&file);
    QString curName, curType, curDefault;
    bool inEntry = false;
    while (!xml.atEnd()) {
        xml.readNext();
        if (xml.isStartElement()) {
            if (xml.name() == QLatin1String("entry")) {
                inEntry = true;
                const auto attrs = xml.attributes();
                curName = attrs.value(QLatin1String("name")).toString();
                curType = attrs.value(QLatin1String("type")).toString();
                curDefault.clear();
            } else if (inEntry && xml.name() == QLatin1String("default")) {
                curDefault = xml.readElementText();
            }
        } else if (xml.isEndElement() && xml.name() == QLatin1String("entry")) {
            inEntry = false;
            if (!curName.isEmpty()) {
                QVariantMap p;
                p.insert(QStringLiteral("name"), curName);
                p.insert(QStringLiteral("type"), curType);
                p.insert(QStringLiteral("default"), curDefault);
                p.insert(QStringLiteral("value"), currentParamValue(effectId, curName, curDefault));
                params.append(p);
            }
        }
    }
    if (xml.hasError()) {
        std::fprintf(stderr, "[kcm] main.xml 解析失败(%s): %s\n",
                     qPrintable(effectId), qPrintable(xml.errorString()));
        return QVariantList();
    }
    return params;
}

// kwinrc 路径：BMW_KCM_KWINRC 覆盖（测试隔离），默认用户 kwinrc。
QString BurnWindowKCM::kwinrcPath() const
{
    const QString override = qEnvironmentVariable("BMW_KCM_KWINRC");
    if (!override.isEmpty()) {
        return override;
    }
    return QDir::homePath() + QStringLiteral("/.config/kwinrc");
}

// 参数当前值：kwinrc 的 [Effect-<id>] 组按名读取，缺失回落 main.xml 默认值。
QString BurnWindowKCM::currentParamValue(const QString &effectId, const QString &name, const QString &defaultValue) const
{
    KConfig cfg(kwinrcPath(), KConfig::SimpleConfig);
    KConfigGroup group(&cfg, QStringLiteral("Effect-") + effectId);
    return group.readEntry(name, defaultValue);
}

// D3 参与语义入口：参与 = 不在黑名单，反转映射在这里完成。
void BurnWindowKCM::toggleParticipating(const QString &effectId, bool participating)
{
    toggleBlacklist(effectId, !participating);
}

// D7 参数编辑：只进脏区（同名参数 upsert，后写覆盖先写），
// 落盘 kwinrc 与重新加载特效统一在 apply() 完成。
void BurnWindowKCM::setParam(const QString &effectId, const QString &name, const QString &value)
{
    for (int i = 0; i < m_paramDirty.size(); ++i) {
        QVariantMap entry = m_paramDirty[i].toMap();
        if (entry.value(QStringLiteral("effectId")) == effectId
            && entry.value(QStringLiteral("name")) == name) {
            entry.insert(QStringLiteral("value"), value);
            m_paramDirty[i] = entry;
            setNeedsSave(true);
            return;
        }
    }
    QVariantMap entry;
    entry.insert(QStringLiteral("effectId"), effectId);
    entry.insert(QStringLiteral("name"), name);
    entry.insert(QStringLiteral("value"), value);
    m_paramDirty.append(entry);
    setNeedsSave(true);
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

// 参数段（Task 8，spec 5.1）：脏区落盘 kwinrc [Effect-<id>]，随后对去重后的
// 特效 id 各调一次 reconfigureEffect 使 KWin 重读配置。
// 失败（qdbus6 不可用/KWin 拒绝）只累积警告到 m_paramWarnings —— 不影响 apply
// 脚本的成败判定：参数已落盘，警告在 finishApply 收口合并展示。
void BurnWindowKCM::writeDirtyParams()
{
    if (m_paramDirty.isEmpty()) {
        return;
    }

    KConfig kcfg(kwinrcPath(), KConfig::SimpleConfig);
    QStringList touchedIds;
    for (const QVariant &item : m_paramDirty) {
        const QVariantMap entry = item.toMap();
        const QString id = entry.value(QStringLiteral("effectId")).toString();
        const QString name = entry.value(QStringLiteral("name")).toString();
        const QString value = entry.value(QStringLiteral("value")).toString();
        KConfigGroup group(&kcfg, QStringLiteral("Effect-") + id);
        // 字符串原样写入：KConfig 的类型化读取端解析十进制 r,g,b、#RRGGBB、
        // #AARRGGBB（本机 KF6 实测三者 readEntry(QColor) 均 valid，Ruling-10）
        group.writeEntry(name, value);
        if (!touchedIds.contains(id)) {
            touchedIds << id;
        }
        std::fprintf(stderr, "BMW_KCM_PARAM_WRITE=%s:%s:%s\n",
                     qPrintable(id), qPrintable(name), qPrintable(value));
    }
    kcfg.sync(); // 全部键先落盘，再触发特效重载

    for (const QString &id : std::as_const(touchedIds)) {
        const int rc = QProcess::execute(QStringLiteral("qdbus6"),
                                          {QStringLiteral("org.kde.KWin"), QStringLiteral("/Effects"),
                                           QStringLiteral("reconfigureEffect"), id});
        std::fprintf(stderr, "BMW_KCM_RECONFIGURE=%s\n", qPrintable(id));
        if (rc != 0) {
            m_paramWarnings += tr("reconfigureEffect %1 失败（退出码 %2）\n").arg(id).arg(rc);
        }
    }
    // 写入完成即清（Ruling-11）：参数已落盘，apply 脚本失败的重试只需重跑脚本
    m_paramDirty.clear();
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

    // 参数段（Task 8）：必须在 m_applyOutput.clear() 之后 —— 警告走
    // m_paramWarnings 独立通道，在 finishApply 收口合并（Ruling-11）
    writeDirtyParams();

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

// 每条 return 路径都必须经过这里：applyRunning 归零 + applyOutput 通告，
// 否则一次超时/启动失败会让状态永远停在 running。
// 框架 Apply 按钮的可用性由基类 needsSave 驱动，不由 applyRunning 驱动
// （kcmutils 的 QML 内容侧没有按钮 enabled 的接入点，见 kquickconfigmodule.h
// 的 ConfigModule 附加属性，只暴露 buttons 与 needsSave）。
// ok=false 时保持 needsSave=true —— 黑名单虽已写入配置但注入未生效，
// 必须让用户能再次点击 Apply 重试。
void BurnWindowKCM::finishApply(bool ok)
{
    // reconfigure 警告在唯一收口合并（Ruling-11）：apply() 中段所有
    // m_applyOutput = 赋值路径（脚本结果/超时/启动失败/脚本缺失）都先于这里
    if (!m_paramWarnings.isEmpty()) {
        if (!m_applyOutput.isEmpty()) {
            m_applyOutput += QLatin1Char('\n');
        }
        m_applyOutput += m_paramWarnings;
        m_paramWarnings.clear();
    }
    m_applyRunning = false;
    emit applyRunningChanged();
    emit applyOutputChanged();
    if (ok) {
        setNeedsSave(false); // 已持久化且已重新注入生效
    }
}

// i18n（2026-09-30）：翻译域注册 —— 域值必须等于 KCM 的 pluginId
// （kcm_burnwindow）。依据：kcmutils KQuickConfigModule::mainUi() 硬编码
// `d->engine->setTranslationDomain(metaData().pluginId())`（KF6 源码
// src/quick/kquickconfigmodule.cpp 实测 2026-09-30），QML i18n() 只认
// pluginId 域 —— catalog 文件名须为 kcm_burnwindow.mo，写别的名字查不到
// （burn-window.mo 三轮 S10 失败的根因）。此处 C++ 侧 applicationDomain
// 对齐同一值，kcm.cpp 内的 i18n() 调用与 QML 共用同一 catalog。
// 无翻译环境（测试 LANG=C / .mo 缺失）时 i18n() fallback 返回英文原文。
// C++ 顶层作用域不允许表达式语句（实测 434 行编译报错），用静态初始化
// lambda：so 加载即执行，早于工厂构造与 QML 加载。
namespace {
const bool g_burnWindowI18nDomain = [] {
    KLocalizedString::setApplicationDomain("kcm_burnwindow");
    return true;
}();
} // namespace

K_PLUGIN_FACTORY_WITH_JSON(BurnWindowKCMFactory, "kcm_burnwindow.json",
                            registerPlugin<BurnWindowKCM>();)

// K_PLUGIN_FACTORY_WITH_JSON 展开含一个带 Q_OBJECT 的工厂类，AUTOMOC 要求显式
// 引入本文件的 moc 输出，否则构建报 "add #include kcm.moc" 并中止（spec 4.8 实测）。
#include "kcm.moc"
