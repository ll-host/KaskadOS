#include <QApplication>
#include <QCloseEvent>
#include <QColor>
#include <QDateTime>
#include <QDesktopServices>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QFileInfo>
#include <QFrame>
#include <QFont>
#include <QGridLayout>
#include <QGroupBox>
#include <QHash>
#include <QHBoxLayout>
#include <QHeaderView>
#include <QInputDialog>
#include <QLabel>
#include <QLineEdit>
#include <QListWidget>
#include <QMainWindow>
#include <QMessageBox>
#include <QPlainTextEdit>
#include <QProcess>
#include <QProcessEnvironment>
#include <QProgressBar>
#include <QPushButton>
#include <QRegularExpression>
#include <QScrollArea>
#include <QSplitter>
#include <QStandardPaths>
#include <QStackedWidget>
#include <QStyle>
#include <QTabWidget>
#include <QTimer>
#include <QToolButton>
#include <QTreeWidget>
#include <QVBoxLayout>

#include <csignal>

namespace {

QString readTextFile(const QString &path)
{
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text))
        return {};
    return QString::fromUtf8(file.readAll()).trimmed();
}

QString runCapture(const QString &program, const QStringList &arguments,
                   const QString &workingDirectory = {})
{
    QProcess process;
    if (!workingDirectory.isEmpty())
        process.setWorkingDirectory(workingDirectory);
    process.start(program, arguments, QIODevice::ReadOnly);
    if (!process.waitForStarted(3000) || !process.waitForFinished(10000))
        return {};
    return QString::fromLocal8Bit(process.readAllStandardOutput()).trimmed();
}

QString humanSize(qint64 bytes)
{
    static const QStringList units{QStringLiteral("Б"), QStringLiteral("КиБ"),
                                   QStringLiteral("МиБ"), QStringLiteral("ГиБ")};
    double value = bytes;
    int unit = 0;
    while (value >= 1024.0 && unit < units.size() - 1) {
        value /= 1024.0;
        ++unit;
    }
    return unit == 0 ? QStringLiteral("%1 %2").arg(bytes).arg(units[unit])
                     : QStringLiteral("%1 %2").arg(value, 0, 'f', 1).arg(units[unit]);
}

QFileInfo newestFile(const QString &directory, const QStringList &filters)
{
    const QDir dir(directory);
    const QFileInfoList files = dir.entryInfoList(filters, QDir::Files,
                                                   QDir::Time | QDir::Reversed);
    QFileInfo newest;
    for (const QFileInfo &file : files) {
        if (!newest.exists() || file.lastModified() > newest.lastModified())
            newest = file;
    }
    return newest;
}

QString artifactText(const QFileInfo &file)
{
    if (!file.exists())
        return QStringLiteral("Не найден");
    return QStringLiteral("%1\n%2 · %3")
        .arg(file.fileName(), humanSize(file.size()),
             file.lastModified().toString(QStringLiteral("dd.MM.yyyy HH:mm")));
}

QString cleanOutput(QString text)
{
    static const QRegularExpression ansi(QStringLiteral("\\x1B(?:[@-Z\\\\-_]|\\[[0-?]*[ -/]*[@-~])"));
    text.remove(ansi);
    text.replace('\r', '\n');
    return text;
}

} // namespace

class ManagerWindow final : public QMainWindow
{
public:
    explicit ManagerWindow(QString projectDirectory)
        : m_projectDirectory(std::move(projectDirectory))
        , m_backend(m_projectDirectory + QStringLiteral("/kaskados-manager.sh"))
        , m_logDirectory(QDir::homePath() + QStringLiteral("/kaskados-logs"))
    {
        setWindowTitle(QStringLiteral("KaskadOS — управление сборками"));
        setMinimumSize(980, 680);
        resize(1180, 790);
        setWindowIcon(style()->standardIcon(QStyle::SP_ComputerIcon));

        buildUi();
        applyStyle();
        connectProcess();

        m_clock.setInterval(1000);
        connect(&m_clock, &QTimer::timeout, this, [this] { updateElapsed(); });
        m_stateRefresh.setInterval(3000);
        connect(&m_stateRefresh, &QTimer::timeout, this, [this] {
            if (m_process.state() == QProcess::NotRunning)
                refreshState();
        });
        m_stateRefresh.start();
        refreshState();
    }

protected:
    void closeEvent(QCloseEvent *event) override
    {
        if (m_process.state() == QProcess::NotRunning) {
            event->accept();
            return;
        }
        QMessageBox::information(this, QStringLiteral("Операция выполняется"),
                                 QStringLiteral("Сначала дождитесь завершения операции или остановите её."));
        event->ignore();
    }

private:
    void buildUi()
    {
        auto *central = new QWidget(this);
        auto *root = new QVBoxLayout(central);
        root->setContentsMargins(28, 24, 28, 24);
        root->setSpacing(18);

        auto *header = new QHBoxLayout;
        auto *titles = new QVBoxLayout;
        auto *title = new QLabel(QStringLiteral("Управление сборками"));
        title->setObjectName(QStringLiteral("pageTitle"));
        auto *subtitle = new QLabel(m_projectDirectory);
        subtitle->setObjectName(QStringLiteral("muted"));
        subtitle->setTextInteractionFlags(Qt::TextSelectableByMouse);
        titles->addWidget(title);
        titles->addWidget(subtitle);
        header->addLayout(titles, 1);

        m_activityBadge = new QPushButton;
        m_activityBadge->setObjectName(QStringLiteral("badge"));
        m_activityBadge->setCursor(Qt::PointingHandCursor);
        connect(m_activityBadge, &QPushButton::clicked, this, [this] {
            if (m_process.state() != QProcess::NotRunning || m_externalOperation
                || !m_currentAction.isEmpty()) {
                m_pages->setCurrentWidget(m_operationPage);
                return;
            }
            manageExternalOperation();
        });
        header->addWidget(m_activityBadge);

        m_resumeExternalButton = new QPushButton(QStringLiteral("Продолжить"));
        m_resumeExternalButton->setObjectName(QStringLiteral("resumeButton"));
        m_resumeExternalButton->hide();
        connect(m_resumeExternalButton, &QPushButton::clicked, this, [this] {
            startExternalControl(QStringLiteral("resume"), QStringLiteral("Продолжение сборки"));
        });
        header->addWidget(m_resumeExternalButton);

        m_stopExternalButton = new QPushButton(QStringLiteral("Завершить"));
        m_stopExternalButton->setObjectName(QStringLiteral("dangerButton"));
        m_stopExternalButton->hide();
        connect(m_stopExternalButton, &QPushButton::clicked, this, [this] { confirmExternalStop(); });
        header->addWidget(m_stopExternalButton);

        auto *refresh = new QToolButton;
        refresh->setToolTip(QStringLiteral("Обновить состояние"));
        refresh->setIcon(style()->standardIcon(QStyle::SP_BrowserReload));
        refresh->setObjectName(QStringLiteral("iconButton"));
        connect(refresh, &QToolButton::clicked, this, [this] { refreshState(); });
        header->addWidget(refresh);
        root->addLayout(header);

        m_pages = new QStackedWidget;
        auto *dashboardPage = new QWidget;
        auto *dashboardLayout = new QVBoxLayout(dashboardPage);
        dashboardLayout->setContentsMargins(0, 0, 0, 0);

        auto *body = new QSplitter(Qt::Horizontal);
        body->setChildrenCollapsible(false);

        auto *operationsScroll = new QScrollArea;
        operationsScroll->setWidgetResizable(true);
        operationsScroll->setFrameShape(QFrame::NoFrame);
        auto *operations = new QWidget;
        auto *operationsLayout = new QVBoxLayout(operations);
        operationsLayout->setContentsMargins(0, 0, 10, 0);
        operationsLayout->setSpacing(16);

        operationsLayout->addWidget(sectionTitle(QStringLiteral("Сборка")));
        auto *buildGrid = new QGridLayout;
        buildGrid->setSpacing(12);
        buildGrid->addWidget(actionButton(QStringLiteral("Собрать ISO"),
                                          QStringLiteral("Подготовить загрузочный образ системы"),
                                          QStringLiteral("build-iso"), {}, true), 0, 0);
        buildGrid->addWidget(actionButton(QStringLiteral("Собрать обновление DE"),
                                          QStringLiteral("Создать пакеты среды и dgop"),
                                          QStringLiteral("build-desktop")), 0, 1);
        buildGrid->addWidget(actionButton(QStringLiteral("Собрать и опубликовать DE"),
                                          QStringLiteral("Полный цикл обновления среды"),
                                          QStringLiteral("build-publish-desktop"),
                                          QStringLiteral("Собрать пакеты и после успеха опубликовать обновление?")), 1, 0, 1, 2);
        operationsLayout->addLayout(buildGrid);

        operationsLayout->addWidget(sectionTitle(QStringLiteral("Публикация")));
        auto *publishGrid = new QGridLayout;
        publishGrid->setSpacing(12);
        publishGrid->addWidget(actionButton(QStringLiteral("Опубликовать DE"),
                                            QStringLiteral("Загрузить готовые пакеты пользователям"),
                                            QStringLiteral("publish-desktop"),
                                            QStringLiteral("Опубликовать последнее обновление DE?")), 0, 0);
        publishGrid->addWidget(actionButton(QStringLiteral("Опубликовать ISO"),
                                            QStringLiteral("SHA256 и загрузка в SourceForge"),
                                            QStringLiteral("publish-iso"),
                                            QStringLiteral("Опубликовать последний ISO в SourceForge?")), 0, 1);
        operationsLayout->addLayout(publishGrid);

        operationsLayout->addWidget(sectionTitle(QStringLiteral("Проект")));
        auto *projectGrid = new QGridLayout;
        projectGrid->setSpacing(12);
        projectGrid->addWidget(actionButton(QStringLiteral("Повысить версию"),
                                            QStringLiteral("Согласованно обновить DE, ISO и манифест"),
                                            QStringLiteral("bump-version"),
                                            QStringLiteral("Повысить alpha-версию DE и ISO?")), 0, 0);
        projectGrid->addWidget(actionButton(QStringLiteral("Коммит и отправка"),
                                            QStringLiteral("Добавить все изменения и отправить в GitHub"),
                                            QStringLiteral("commit-push")), 0, 1);
        projectGrid->addWidget(actionButton(QStringLiteral("Очистить журналы"),
                                            QStringLiteral("Удалить сохранённые журналы операций"),
                                            QStringLiteral("clear-logs"),
                                            QStringLiteral("Удалить все журналы сборок и публикаций?"), false, true), 1, 0);
        auto *openProject = new QPushButton(QStringLiteral("Открыть папку проекта\nФайлы исходного кода и сборки"));
        openProject->setObjectName(QStringLiteral("actionButton"));
        openProject->setProperty("secondary", true);
        connect(openProject, &QPushButton::clicked, this, [this] {
            QDesktopServices::openUrl(QUrl::fromLocalFile(m_projectDirectory));
        });
        projectGrid->addWidget(openProject, 1, 1);
        operationsLayout->addLayout(projectGrid);
        operationsLayout->addStretch();
        operationsScroll->setWidget(operations);
        body->addWidget(operationsScroll);

        auto *sidebar = new QWidget;
        sidebar->setMinimumWidth(330);
        sidebar->setMaximumWidth(390);
        auto *sideLayout = new QVBoxLayout(sidebar);
        sideLayout->setContentsMargins(8, 0, 0, 0);
        sideLayout->setSpacing(12);

        sideLayout->addWidget(sectionTitle(QStringLiteral("Состояние")));
        auto *stateCard = new QFrame;
        stateCard->setObjectName(QStringLiteral("card"));
        auto *stateLayout = new QVBoxLayout(stateCard);
        stateLayout->setSpacing(12);
        m_versionLabel = stateRow(stateLayout, QStringLiteral("Версия"));
        m_gitLabel = stateRow(stateLayout, QStringLiteral("Git"));
        m_isoLabel = stateRow(stateLayout, QStringLiteral("Последний ISO"));
        m_packageLabel = stateRow(stateLayout, QStringLiteral("Пакет DE"));
        sideLayout->addWidget(stateCard);

        auto *artifactButtons = new QHBoxLayout;
        auto *openOutput = new QPushButton(QStringLiteral("Готовые файлы"));
        openOutput->setObjectName(QStringLiteral("smallButton"));
        connect(openOutput, &QPushButton::clicked, this, [this] {
            QDesktopServices::openUrl(QUrl::fromLocalFile(m_projectDirectory + QStringLiteral("/out")));
        });
        auto *openLogs = new QPushButton(QStringLiteral("Папка журналов"));
        openLogs->setObjectName(QStringLiteral("smallButton"));
        connect(openLogs, &QPushButton::clicked, this, [this] {
            QDir().mkpath(m_logDirectory);
            QDesktopServices::openUrl(QUrl::fromLocalFile(m_logDirectory));
        });
        artifactButtons->addWidget(openOutput);
        artifactButtons->addWidget(openLogs);
        sideLayout->addLayout(artifactButtons);

        sideLayout->addWidget(sectionTitle(QStringLiteral("Последние журналы")));
        m_logs = new QListWidget;
        m_logs->setObjectName(QStringLiteral("logs"));
        m_logs->setMinimumHeight(150);
        connect(m_logs, &QListWidget::itemDoubleClicked, this, [](QListWidgetItem *item) {
            QDesktopServices::openUrl(QUrl::fromLocalFile(item->data(Qt::UserRole).toString()));
        });
        sideLayout->addWidget(m_logs, 1);
        body->addWidget(sidebar);
        body->setStretchFactor(0, 1);
        body->setStretchFactor(1, 0);
        dashboardLayout->addWidget(body);

        auto *consolePanel = new QFrame;
        consolePanel->setObjectName(QStringLiteral("consolePanel"));
        auto *consoleLayout = new QVBoxLayout(consolePanel);
        consoleLayout->setContentsMargins(16, 12, 16, 14);
        auto *consoleHeader = new QHBoxLayout;
        auto *backToDashboard = new QPushButton(QStringLiteral("←  Управление"));
        backToDashboard->setObjectName(QStringLiteral("smallButton"));
        backToDashboard->setToolTip(QStringLiteral("Вернуться к основным действиям"));
        connect(backToDashboard, &QPushButton::clicked, this, [this] {
            m_pages->setCurrentWidget(m_dashboardPage);
        });
        m_operationTitle = new QLabel(QStringLiteral("Журнал выполнения"));
        m_operationTitle->setObjectName(QStringLiteral("sectionTitle"));
        m_elapsedLabel = new QLabel;
        m_elapsedLabel->setObjectName(QStringLiteral("muted"));
        m_progress = new QProgressBar;
        m_progress->setRange(0, 0);
        m_progress->setTextVisible(false);
        m_progress->setFixedWidth(130);
        m_progress->hide();
        m_cancelButton = new QPushButton(QStringLiteral("Остановить"));
        m_cancelButton->setObjectName(QStringLiteral("dangerButton"));
        m_cancelButton->hide();
        connect(m_cancelButton, &QPushButton::clicked, this, [this] { cancelOperation(); });
        consoleHeader->addWidget(backToDashboard);
        consoleHeader->addSpacing(8);
        consoleHeader->addWidget(m_operationTitle);
        consoleHeader->addStretch();
        consoleHeader->addWidget(m_elapsedLabel);
        consoleHeader->addWidget(m_progress);
        consoleHeader->addWidget(m_cancelButton);
        consoleLayout->addLayout(consoleHeader);

        m_operationTabs = new QTabWidget;
        m_operationTabs->setObjectName(QStringLiteral("operationTabs"));

        auto *overviewPage = new QWidget;
        auto *overviewLayout = new QVBoxLayout(overviewPage);
        overviewLayout->setContentsMargins(8, 10, 8, 8);
        auto *phaseGrid = new QGridLayout;
        phaseGrid->setSpacing(8);
        const QList<QPair<QString, QString>> phases{
            {QStringLiteral("checks"), QStringLiteral("1  Проверка среды")},
            {QStringLiteral("cleanup"), QStringLiteral("2  Очистка рабочей папки")},
            {QStringLiteral("profile"), QStringLiteral("3  Сборка компонентов")},
            {QStringLiteral("packages"), QStringLiteral("4  Пакеты системы")},
            {QStringLiteral("configure"), QStringLiteral("5  Настройка live-среды")},
            {QStringLiteral("compress"), QStringLiteral("6  Сжатие файловой системы")},
            {QStringLiteral("image"), QStringLiteral("7  Создание загрузочного ISO")},
            {QStringLiteral("complete"), QStringLiteral("8  Проверка результата")}};
        for (int index = 0; index < phases.size(); ++index) {
            auto *phase = new QLabel(phases[index].second + QStringLiteral("\nОжидает"));
            phase->setObjectName(QStringLiteral("phase"));
            phase->setProperty("state", QStringLiteral("waiting"));
            phase->setMinimumHeight(54);
            phaseGrid->addWidget(phase, index / 4, index % 4);
            m_phaseLabels.insert(phases[index].first, phase);
        }
        overviewLayout->addLayout(phaseGrid);
        m_packageSummary = new QLabel(QStringLiteral("Пакеты: 0 установлено · 0 скачивается · 0 повторов · 0 ошибок"));
        m_packageSummary->setObjectName(QStringLiteral("packageSummary"));
        overviewLayout->addWidget(m_packageSummary);
        consoleLayout->addWidget(overviewPage);

        auto *packagesPage = new QWidget;
        auto *packagesLayout = new QVBoxLayout(packagesPage);
        packagesLayout->setContentsMargins(8, 8, 8, 8);
        m_packageFilter = new QLineEdit;
        m_packageFilter->setPlaceholderText(QStringLiteral("Найти пакет…"));
        packagesLayout->addWidget(m_packageFilter);
        m_packageTree = new QTreeWidget;
        m_packageTree->setColumnCount(3);
        m_packageTree->setHeaderLabels({QStringLiteral("Пакет"), QStringLiteral("Состояние"), QStringLiteral("Попытка")});
        m_packageTree->header()->setSectionResizeMode(0, QHeaderView::Stretch);
        m_packageTree->header()->setSectionResizeMode(1, QHeaderView::ResizeToContents);
        m_packageTree->header()->setSectionResizeMode(2, QHeaderView::ResizeToContents);
        m_packageTree->setAlternatingRowColors(true);
        packagesLayout->addWidget(m_packageTree, 1);
        connect(m_packageFilter, &QLineEdit::textChanged, this, [this](const QString &query) {
            for (auto iterator = m_packageItems.cbegin(); iterator != m_packageItems.cend(); ++iterator)
                iterator.value()->setHidden(!iterator.key().contains(query, Qt::CaseInsensitive));
        });
        m_operationTabs->addTab(packagesPage, QStringLiteral("Пакеты"));

        m_console = new QPlainTextEdit;
        m_console->setReadOnly(true);
        m_console->setObjectName(QStringLiteral("console"));
        m_console->setPlaceholderText(QStringLiteral("Здесь появится ход выбранной операции."));
        m_console->document()->setMaximumBlockCount(12000);
        m_operationTabs->addTab(m_console, QStringLiteral("Полный журнал"));
        consoleLayout->addWidget(m_operationTabs);

        m_dashboardPage = dashboardPage;
        m_operationPage = consolePanel;
        m_pages->addWidget(m_dashboardPage);
        m_pages->addWidget(m_operationPage);
        m_pages->setCurrentWidget(m_dashboardPage);
        root->addWidget(m_pages, 1);
        setCentralWidget(central);
        initializePackageTree();
        resetBuildDetails();
    }

    QLabel *sectionTitle(const QString &text)
    {
        auto *label = new QLabel(text);
        label->setObjectName(QStringLiteral("sectionTitle"));
        return label;
    }

    QLabel *stateRow(QVBoxLayout *layout, const QString &title)
    {
        auto *caption = new QLabel(title);
        caption->setObjectName(QStringLiteral("stateCaption"));
        auto *value = new QLabel(QStringLiteral("—"));
        value->setObjectName(QStringLiteral("stateValue"));
        value->setWordWrap(true);
        value->setTextInteractionFlags(Qt::TextSelectableByMouse);
        layout->addWidget(caption);
        layout->addWidget(value);
        return value;
    }

    QPushButton *actionButton(const QString &title, const QString &description,
                              const QString &action, const QString &confirmation = {},
                              bool primary = false, bool danger = false)
    {
        auto *button = new QPushButton(QStringLiteral("%1\n%2").arg(title, description));
        button->setObjectName(QStringLiteral("actionButton"));
        button->setProperty("primary", primary);
        button->setProperty("danger", danger);
        button->setCursor(Qt::PointingHandCursor);
        button->setMinimumHeight(68);
        m_actionButtons.append(button);
        connect(button, &QPushButton::clicked, this, [this, action, title, confirmation] {
            startAction(action, title, confirmation);
        });
        return button;
    }

    QString packageGroup(const QString &name) const
    {
        if (name == QStringLiteral("linux") || name.startsWith(QStringLiteral("linux-"))
            || name.endsWith(QStringLiteral("-ucode")) || name.contains(QStringLiteral("firmware")))
            return QStringLiteral("Ядро и прошивки");
        if (name.startsWith(QStringLiteral("nvidia")) || name.startsWith(QStringLiteral("lib32-"))
            || name.contains(QStringLiteral("vulkan")) || name == QStringLiteral("mesa"))
            return QStringLiteral("Графика и драйверы");
        if (name.startsWith(QLatin1Char('k')) || name.startsWith(QStringLiteral("plasma"))
            || name.startsWith(QStringLiteral("qt6")) || name.contains(QStringLiteral("wayland"))
            || name.contains(QStringLiteral("portal")) || name == QStringLiteral("quickshell"))
            return QStringLiteral("Рабочая среда");
        if (name.contains(QStringLiteral("font")) || name.startsWith(QStringLiteral("ttf-"))
            || name == QStringLiteral("fontconfig") || name == QStringLiteral("freetype2"))
            return QStringLiteral("Шрифты и оформление");
        if (name.contains(QStringLiteral("network")) || name.contains(QStringLiteral("wireless"))
            || name == QStringLiteral("iwd") || name == QStringLiteral("wpa_supplicant")
            || name == QStringLiteral("curl") || name == QStringLiteral("openssh")
            || name == QStringLiteral("openvpn") || name == QStringLiteral("dnsmasq"))
            return QStringLiteral("Сеть");
        if (name.contains(QStringLiteral("grub")) || name.contains(QStringLiteral("syslinux"))
            || name.contains(QStringLiteral("mkinitcpio")) || name == QStringLiteral("archinstall")
            || name == QStringLiteral("calamares") || name == QStringLiteral("efibootmgr"))
            return QStringLiteral("Загрузка и установщик");
        if (name == QStringLiteral("base") || name == QStringLiteral("base-devel")
            || name == QStringLiteral("glibc") || name == QStringLiteral("systemd-libs")
            || name == QStringLiteral("sudo") || name == QStringLiteral("pacman-contrib"))
            return QStringLiteral("Базовая система");
        return QStringLiteral("Приложения и инструменты");
    }

    void initializePackageTree()
    {
        m_packageTree->clear();
        m_packageItems.clear();
        m_packageGroups.clear();
        QStringList groupOrder{
            QStringLiteral("Базовая система"), QStringLiteral("Ядро и прошивки"),
            QStringLiteral("Графика и драйверы"), QStringLiteral("Рабочая среда"),
            QStringLiteral("Сеть"), QStringLiteral("Загрузка и установщик"),
            QStringLiteral("Шрифты и оформление"), QStringLiteral("Приложения и инструменты")};
        groupOrder << QStringLiteral("Автоматические зависимости");
        for (const QString &groupName : groupOrder) {
            auto *group = new QTreeWidgetItem(m_packageTree, {groupName, QStringLiteral("0 / 0"), {}});
            group->setExpanded(true);
            QFont font = group->font(0);
            font.setBold(true);
            group->setFont(0, font);
            m_packageGroups.insert(groupName, group);
        }

        const QStringList lines = readTextFile(m_projectDirectory + QStringLiteral("/profile/packages.x86_64")).split('\n');
        for (const QString &rawLine : lines) {
            const QString name = rawLine.trimmed();
            if (name.isEmpty() || name.startsWith(QLatin1Char('#')))
                continue;
            QTreeWidgetItem *group = m_packageGroups.value(packageGroup(name));
            auto *item = new QTreeWidgetItem(group, {name, QStringLiteral("Ожидает"), QStringLiteral("—")});
            item->setData(1, Qt::UserRole, QStringLiteral("waiting"));
            m_packageItems.insert(name, item);
        }
        updatePackageCounters();
    }

    void resetBuildDetails()
    {
        for (auto iterator = m_phaseLabels.cbegin(); iterator != m_phaseLabels.cend(); ++iterator)
            setPhase(iterator.key(), QStringLiteral("waiting"));
        for (auto iterator = m_packageItems.cbegin(); iterator != m_packageItems.cend(); ++iterator)
            setPackageStatus(iterator.key(), QStringLiteral("waiting"), 0, false);
        updatePackageCounters();
    }

    void setPhase(const QString &id, const QString &state)
    {
        QLabel *label = m_phaseLabels.value(id);
        if (!label)
            return;
        const QString title = label->text().section('\n', 0, 0);
        const QHash<QString, QString> captions{{QStringLiteral("waiting"), QStringLiteral("Ожидает")},
                                               {QStringLiteral("running"), QStringLiteral("Выполняется…")},
                                               {QStringLiteral("done"), QStringLiteral("Готово")},
                                               {QStringLiteral("failed"), QStringLiteral("Ошибка")}};
        label->setText(title + QLatin1Char('\n') + captions.value(state, state));
        label->setProperty("state", state);
        label->style()->unpolish(label);
        label->style()->polish(label);
    }

    void setPackageStatus(const QString &name, const QString &state, int attempt, bool refresh = true)
    {
        if (name.isEmpty())
            return;
        QTreeWidgetItem *item = m_packageItems.value(name);
        if (!item) {
            QTreeWidgetItem *group = m_packageGroups.value(QStringLiteral("Автоматические зависимости"));
            item = new QTreeWidgetItem(group, {name, QStringLiteral("Ожидает"), QStringLiteral("—")});
            item->setData(1, Qt::UserRole, QStringLiteral("waiting"));
            m_packageItems.insert(name, item);
        }
        const QHash<QString, QString> captions{{QStringLiteral("waiting"), QStringLiteral("Ожидает")},
                                               {QStringLiteral("downloading"), QStringLiteral("Скачивается")},
                                               {QStringLiteral("downloaded"), QStringLiteral("Скачан")},
                                               {QStringLiteral("retrying"), QStringLiteral("Повтор")},
                                               {QStringLiteral("installed"), QStringLiteral("Установлен")},
                                               {QStringLiteral("failed"), QStringLiteral("Ошибка")}};
        const QHash<QString, QColor> colors{{QStringLiteral("waiting"), QColor(QStringLiteral("#7d8a82"))},
                                            {QStringLiteral("downloading"), QColor(QStringLiteral("#91c7f2"))},
                                            {QStringLiteral("downloaded"), QColor(QStringLiteral("#b9d7c4"))},
                                            {QStringLiteral("retrying"), QColor(QStringLiteral("#efc66f"))},
                                            {QStringLiteral("installed"), QColor(QStringLiteral("#96dfb2"))},
                                            {QStringLiteral("failed"), QColor(QStringLiteral("#f09a94"))}};
        item->setText(1, captions.value(state, state));
        item->setText(2, attempt > 0 ? QString::number(attempt) : QStringLiteral("—"));
        item->setData(1, Qt::UserRole, state);
        item->setForeground(1, colors.value(state));
        if (refresh)
            updatePackageCounters();
    }

    QString packageNameFromFile(const QString &fileName) const
    {
        QString best;
        for (auto iterator = m_packageItems.cbegin(); iterator != m_packageItems.cend(); ++iterator) {
            const QString prefix = iterator.key() + QLatin1Char('-');
            if (fileName.startsWith(prefix) && iterator.key().size() > best.size())
                best = iterator.key();
        }
        if (!best.isEmpty())
            return best;
        static const QRegularExpression packageFilePattern(
            QStringLiteral("^(.+)-[^-]+-[^-]+-(?:x86_64|any)\\.pkg\\.tar\\."));
        return packageFilePattern.match(fileName).captured(1);
    }

    void updatePackageCounters()
    {
        QHash<QString, int> totals;
        QHash<QString, int> installedByGroup;
        int installed = 0;
        int downloaded = 0;
        int downloading = 0;
        int retrying = 0;
        int failed = 0;
        for (auto iterator = m_packageItems.cbegin(); iterator != m_packageItems.cend(); ++iterator) {
            const QString state = iterator.value()->data(1, Qt::UserRole).toString();
            const QString group = iterator.value()->parent()->text(0);
            ++totals[group];
            if (state == QStringLiteral("installed")) {
                ++installed;
                ++installedByGroup[group];
            } else if (state == QStringLiteral("downloaded")) {
                ++downloaded;
                ++installedByGroup[group];
            } else if (state == QStringLiteral("downloading")) {
                ++downloading;
            } else if (state == QStringLiteral("failed")) {
                ++failed;
            }
            if (state == QStringLiteral("retrying") || iterator.value()->text(2).toInt() > 1)
                ++retrying;
        }
        for (auto iterator = m_packageGroups.cbegin(); iterator != m_packageGroups.cend(); ++iterator)
            iterator.value()->setText(1, QStringLiteral("%1 / %2").arg(installedByGroup[iterator.key()]).arg(totals[iterator.key()]));
        m_packageSummary->setText(QStringLiteral("Пакеты: %1 скачано · %2 установлено · %3 скачивается · %4 с повторами · %5 ошибок · всего %6")
                                      .arg(downloaded).arg(installed).arg(downloading).arg(retrying).arg(failed).arg(m_packageItems.size()));
    }

    void connectProcess()
    {
        m_process.setProcessChannelMode(QProcess::MergedChannels);
        connect(&m_process, &QProcess::readyRead, this, [this] {
            processOutput(QString::fromLocal8Bit(m_process.readAll()));
        });
        connect(&m_process, &QProcess::errorOccurred, this, [this](QProcess::ProcessError error) {
            if (error == QProcess::FailedToStart)
                appendOutput(QStringLiteral("Не удалось запустить внутреннюю команду.\n"));
        });
        connect(&m_process, qOverload<int, QProcess::ExitStatus>(&QProcess::finished),
                this, [this](int exitCode, QProcess::ExitStatus exitStatus) {
            m_clock.stop();
            updateBusyState(false);
            const bool success = exitStatus == QProcess::NormalExit && exitCode == 0;
            if (m_currentAction == QStringLiteral("build-iso"))
                finishBuildDetails(success);
            const QString result = success
                ? QStringLiteral("Готово")
                : (m_cancelRequested ? QStringLiteral("Остановлено")
                                     : QStringLiteral("Ошибка · код %1").arg(exitCode));
            m_operationTitle->setText(QStringLiteral("%1 — %2").arg(m_currentTitle, result));
            appendOutput(success ? QStringLiteral("\nОперация завершена успешно.\n")
                                 : QStringLiteral("\nОперация завершилась с ошибкой. Подробности выше.\n"));
            refreshState();
        });
    }

    void startAction(const QString &action, const QString &title, const QString &confirmation)
    {
        if (m_process.state() != QProcess::NotRunning)
            return;

        QString commitMessage;
        if (action == QStringLiteral("commit-push")) {
            bool accepted = false;
            commitMessage = QInputDialog::getText(this, QStringLiteral("Коммит и отправка"),
                                                   QStringLiteral("Название коммита:"),
                                                   QLineEdit::Normal, {}, &accepted).trimmed();
            if (!accepted)
                return;
            if (commitMessage.isEmpty()) {
                QMessageBox::warning(this, QStringLiteral("Нет названия"),
                                     QStringLiteral("Название коммита не может быть пустым."));
                return;
            }
            const auto answer = QMessageBox::question(
                this, QStringLiteral("Отправить изменения?"),
                QStringLiteral("Все изменения проекта будут добавлены в коммит «%1» и отправлены в текущую ветку GitHub.").arg(commitMessage),
                QMessageBox::Cancel | QMessageBox::Yes, QMessageBox::Cancel);
            if (answer != QMessageBox::Yes)
                return;
        } else if (!confirmation.isEmpty()) {
            const auto answer = QMessageBox::question(this, title, confirmation,
                                                       QMessageBox::Cancel | QMessageBox::Yes,
                                                       QMessageBox::Cancel);
            if (answer != QMessageBox::Yes)
                return;
        }

        QProcessEnvironment environment = QProcessEnvironment::systemEnvironment();
        environment.insert(QStringLiteral("KASKADOS_ASSUME_YES"), QStringLiteral("1"));
        environment.insert(QStringLiteral("KASKADOS_PRIVILEGE_HELPER"), QStringLiteral("pkexec"));
        if (!commitMessage.isEmpty())
            environment.insert(QStringLiteral("KASKADOS_COMMIT_MESSAGE"), commitMessage);

        m_process.setProcessEnvironment(environment);
        m_process.setWorkingDirectory(m_projectDirectory);
        m_process.setProgram(QStringLiteral("/usr/bin/setsid"));
        m_process.setArguments({m_backend, QStringLiteral("--action"), action});
        m_console->clear();
        m_currentTitle = title;
        m_currentAction = action;
        m_cancelRequested = false;
        m_operationTitle->setText(title);
        appendOutput(QStringLiteral("Запуск: %1\n\n").arg(title));
        m_elapsed.start();
        m_clock.start();
        if (action == QStringLiteral("build-iso")) {
            resetBuildDetails();
            m_operationTabs->setCurrentIndex(0);
        } else {
            m_operationTabs->setCurrentIndex(1);
        }
        m_pages->setCurrentWidget(m_operationPage);
        updateBusyState(true);
        m_process.start();
    }

    void cancelOperation()
    {
        if (m_process.state() == QProcess::NotRunning)
            return;
        const auto answer = QMessageBox::question(
            this, QStringLiteral("Остановить операцию?"),
            QStringLiteral("Текущая команда будет прервана. Уже созданные файлы и кэш останутся на диске."),
            QMessageBox::Cancel | QMessageBox::Yes, QMessageBox::Cancel);
        if (answer != QMessageBox::Yes)
            return;

        m_cancelRequested = true;
        m_cancelButton->setEnabled(false);
        const qint64 pid = m_process.processId();
        if (pid > 0)
            ::kill(-static_cast<pid_t>(pid), SIGINT);
        QTimer::singleShot(5000, this, [this, pid] {
            if (m_process.state() != QProcess::NotRunning && pid > 0)
                ::kill(-static_cast<pid_t>(pid), SIGTERM);
        });
    }

    void manageExternalOperation()
    {
        if (!m_externalOperation || m_externalPid <= 1)
            return;

        QMessageBox dialog(this);
        dialog.setWindowTitle(m_externalStopped ? QStringLiteral("Приостановленная сборка")
                                                : QStringLiteral("Сборка выполняется"));
        dialog.setIcon(QMessageBox::Information);
        dialog.setText(m_externalStopped
                           ? QStringLiteral("Предыдущая сборка ISO была приостановлена вне этого окна.")
                           : QStringLiteral("Сборка ISO запущена вне этого окна и продолжает работу."));
        dialog.setInformativeText(QStringLiteral("Загруженные пакеты при любом выборе останутся в кэше."));
        QAbstractButton *resume = nullptr;
        if (m_externalStopped)
            resume = dialog.addButton(QStringLiteral("Продолжить"), QMessageBox::AcceptRole);
        auto *stop = dialog.addButton(QStringLiteral("Завершить"), QMessageBox::DestructiveRole);
        dialog.addButton(QMessageBox::Cancel);
        dialog.exec();

        if (dialog.clickedButton() == resume) {
            startExternalControl(QStringLiteral("resume"), QStringLiteral("Продолжение сборки"));
        } else if (dialog.clickedButton() == stop) {
            confirmExternalStop();
        }
    }

    void confirmExternalStop()
    {
        const auto answer = QMessageBox::question(
            this, QStringLiteral("Завершить сборку?"),
            QStringLiteral("Текущая незавершённая сборка будет остановлена. Кэш загрузок сохранится."),
            QMessageBox::Cancel | QMessageBox::Yes, QMessageBox::Cancel);
        if (answer == QMessageBox::Yes)
            startExternalControl(QStringLiteral("stop"), QStringLiteral("Завершение сборки"));
    }

    void startExternalControl(const QString &action, const QString &title)
    {
        m_process.setProcessEnvironment(QProcessEnvironment::systemEnvironment());
        m_process.setWorkingDirectory(m_projectDirectory);
        m_process.setProgram(m_projectDirectory + QStringLiteral("/scripts/manage-build-process.sh"));
        m_process.setArguments({action, QString::number(m_externalPid)});
        m_console->clear();
        m_currentTitle = title;
        m_cancelRequested = false;
        m_operationTitle->setText(title);
        appendOutput(QStringLiteral("%1…\n\n").arg(title));
        m_elapsed.start();
        m_clock.start();
        m_operationTabs->setCurrentIndex(1);
        m_pages->setCurrentWidget(m_operationPage);
        updateBusyState(true);
        m_process.start();
    }

    void updateBusyState(bool busy)
    {
        m_progress->setVisible(busy);
        m_cancelButton->setVisible(busy);
        m_cancelButton->setEnabled(busy);
        for (QPushButton *button : std::as_const(m_actionButtons))
            button->setEnabled(!busy && !m_externalOperation);
    }

    void updateElapsed()
    {
        const qint64 seconds = m_elapsed.elapsed() / 1000;
        m_elapsedLabel->setText(QStringLiteral("%1:%2")
                                    .arg(seconds / 60, 2, 10, QLatin1Char('0'))
                                    .arg(seconds % 60, 2, 10, QLatin1Char('0')));
    }

    void appendOutput(const QString &text)
    {
        if (text.isEmpty())
            return;
        m_console->moveCursor(QTextCursor::End);
        m_console->insertPlainText(text);
        m_console->moveCursor(QTextCursor::End);
    }

    void processOutput(const QString &chunk)
    {
        m_outputBuffer += cleanOutput(chunk);
        qsizetype newline = -1;
        while ((newline = m_outputBuffer.indexOf(QLatin1Char('\n'))) >= 0) {
            const QString line = m_outputBuffer.left(newline);
            m_outputBuffer.remove(0, newline + 1);
            processOutputLine(line);
        }
    }

    void processOutputLine(const QString &line)
    {
        if (line.startsWith(QStringLiteral("@@KASKADOS@@\t"))) {
            const QStringList fields = line.split('\t');
            if (fields.size() >= 5 && fields[1] == QStringLiteral("package")) {
                const QString package = packageNameFromFile(fields[2]);
                setPackageStatus(package, fields[3], fields[4].toInt());
            } else if (fields.size() >= 4 && fields[1] == QStringLiteral("phase")) {
                setPhase(fields[2], fields[3]);
            }
            return;
        }

        if (m_currentAction == QStringLiteral("build-iso")) {
            if (line.contains(QStringLiteral("Installing packages to")))
                setPhase(QStringLiteral("packages"), QStringLiteral("running"));
            if (line.contains(QStringLiteral("Done! Packages installed successfully"))) {
                setPhase(QStringLiteral("packages"), QStringLiteral("done"));
                setPhase(QStringLiteral("configure"), QStringLiteral("running"));
            }
            if (line.contains(QStringLiteral("Creating SquashFS image"))) {
                setPhase(QStringLiteral("configure"), QStringLiteral("done"));
                setPhase(QStringLiteral("compress"), QStringLiteral("running"));
            }
            if (line.contains(QStringLiteral("Setting up SYSLINUX"))
                || line.contains(QStringLiteral("Creating FAT image"))) {
                setPhase(QStringLiteral("compress"), QStringLiteral("done"));
                setPhase(QStringLiteral("image"), QStringLiteral("running"));
            }
            if (line.contains(QStringLiteral("Creating ISO image")))
                setPhase(QStringLiteral("image"), QStringLiteral("running"));

            static const QRegularExpression installedPattern(
                QStringLiteral("(?:installing|установка)\\s+([A-Za-z0-9@._+:-]+)"),
                QRegularExpression::CaseInsensitiveOption);
            const QRegularExpressionMatch installedMatch = installedPattern.match(line);
            if (installedMatch.hasMatch())
                setPackageStatus(installedMatch.captured(1), QStringLiteral("installed"), 0);
        }
        appendOutput(line + QLatin1Char('\n'));
    }

    void finishBuildDetails(bool success)
    {
        if (!m_outputBuffer.isEmpty()) {
            processOutputLine(m_outputBuffer);
            m_outputBuffer.clear();
        }
        if (success) {
            for (auto iterator = m_phaseLabels.cbegin(); iterator != m_phaseLabels.cend(); ++iterator)
                setPhase(iterator.key(), QStringLiteral("done"));
        } else {
            for (auto iterator = m_phaseLabels.cbegin(); iterator != m_phaseLabels.cend(); ++iterator) {
                if (iterator.value()->property("state").toString() == QStringLiteral("running"))
                    setPhase(iterator.key(), QStringLiteral("failed"));
            }
        }
    }

    void refreshState()
    {
        const QString version = readTextFile(m_projectDirectory + QStringLiteral("/components/macqueende/VERSION"));
        const QString profile = readTextFile(m_projectDirectory + QStringLiteral("/profile/profiledef.sh"));
        const QRegularExpression versionPattern(QStringLiteral("iso_version=\"([^\"]+)\""));
        const QString isoVersion = versionPattern.match(profile).captured(1);
        m_versionLabel->setText(version == isoVersion || isoVersion.isEmpty()
                                    ? (version.isEmpty() ? QStringLiteral("Неизвестна") : version)
                                    : QStringLiteral("DE %1 · ISO %2").arg(version, isoVersion));

        const QString branch = runCapture(QStringLiteral("git"),
                                          {QStringLiteral("branch"), QStringLiteral("--show-current")},
                                          m_projectDirectory);
        const QString changesText = runCapture(QStringLiteral("git"),
                                               {QStringLiteral("status"), QStringLiteral("--porcelain=v1")},
                                               m_projectDirectory);
        const int changes = changesText.isEmpty() ? 0 : changesText.count('\n') + 1;
        m_gitLabel->setText(QStringLiteral("%1 · %2")
                                .arg(branch.isEmpty() ? QStringLiteral("неизвестная ветка") : branch,
                                     changes == 0 ? QStringLiteral("без изменений")
                                                  : QStringLiteral("изменений: %1").arg(changes)));

        const QFileInfo iso = newestFile(m_projectDirectory + QStringLiteral("/out"),
                                         {QStringLiteral("*.iso")});
        const QString packageVersion = version;
        QStringList packageFilters{QStringLiteral("kaskados-desktop-*.pkg.tar.zst")};
        if (!packageVersion.isEmpty()) {
            QString normalized = packageVersion;
            normalized.replace('-', '_');
            packageFilters.prepend(QStringLiteral("kaskados-desktop-%1-*.pkg.tar.zst").arg(normalized));
        }
        const QFileInfo package = newestFile(m_projectDirectory + QStringLiteral("/out/packages/x86_64"),
                                             packageFilters);
        const QFileInfo dgop = newestFile(m_projectDirectory + QStringLiteral("/out/packages/x86_64"),
                                          {QStringLiteral("dgop-*.pkg.tar.zst")});
        m_isoLabel->setText(artifactText(iso));
        if (!package.exists() && !dgop.exists()) {
            m_packageLabel->setText(QStringLiteral("Не найдены"));
        } else {
            QStringList packages;
            if (package.exists())
                packages << QStringLiteral("DE: %1 · %2").arg(package.fileName(), humanSize(package.size()));
            if (dgop.exists())
                packages << QStringLiteral("dgop: %1 · %2").arg(dgop.fileName(), humanSize(dgop.size()));
            m_packageLabel->setText(packages.join('\n'));
        }

        refreshLogs();
        detectExternalOperation();
    }

    void refreshLogs()
    {
        m_logs->clear();
        const QDir directory(m_logDirectory);
        const QFileInfoList files = directory.entryInfoList({QStringLiteral("*.log")},
                                                             QDir::Files, QDir::Time);
        int shown = 0;
        for (const QFileInfo &file : files) {
            if (file.isSymLink())
                continue;
            auto *item = new QListWidgetItem(
                QStringLiteral("%1\n%2 · %3")
                    .arg(file.fileName(), file.lastModified().toString(QStringLiteral("dd.MM HH:mm")),
                         humanSize(file.size())));
            item->setData(Qt::UserRole, file.absoluteFilePath());
            m_logs->addItem(item);
            if (++shown == 8)
                break;
        }
        if (shown == 0) {
            auto *empty = new QListWidgetItem(QStringLiteral("Журналов пока нет"));
            empty->setFlags(Qt::NoItemFlags);
            m_logs->addItem(empty);
        }
    }

    bool lineIsIsoOperation(const QString &name) const
    {
        return name.contains(QStringLiteral("build-iso"))
            || name.contains(QStringLiteral("iso-profile"));
    }

    void syncPackageCache()
    {
        const QDir cache(m_projectDirectory + QStringLiteral("/build/package-cache"));
        const QFileInfoList files = cache.entryInfoList(
            {QStringLiteral("*.pkg.tar.*")}, QDir::Files, QDir::Name);
        for (const QFileInfo &file : files) {
            if (file.fileName().endsWith(QStringLiteral(".sig")))
                continue;
            QString packageFile = file.fileName();
            const bool partial = packageFile.endsWith(QStringLiteral(".part"));
            if (partial)
                packageFile.chop(5);
            const QString package = packageNameFromFile(packageFile);
            QTreeWidgetItem *item = m_packageItems.value(package);
            if (item && item->data(1, Qt::UserRole).toString() == QStringLiteral("installed"))
                continue;
            setPackageStatus(package,
                             partial ? QStringLiteral("downloading") : QStringLiteral("downloaded"),
                             partial ? 1 : 0, false);
        }
        syncInstalledPackages();
        updatePackageCounters();
    }

    void syncInstalledPackages()
    {
        const QDir database(m_projectDirectory
                            + QStringLiteral("/work/x86_64/airootfs/var/lib/pacman/local"));
        const QFileInfoList entries = database.entryInfoList(
            QDir::Dirs | QDir::NoDotAndDotDot, QDir::Name);
        static const QRegularExpression namePattern(QStringLiteral("%NAME%\\n([^\\n]+)"));
        for (const QFileInfo &entry : entries) {
            const QString description = readTextFile(entry.absoluteFilePath() + QStringLiteral("/desc"));
            const QString package = namePattern.match(description).captured(1).trimmed();
            if (!package.isEmpty())
                setPackageStatus(package, QStringLiteral("installed"), 0, false);
        }
    }

    void detectExternalOperation()
    {
        if (m_process.state() != QProcess::NotRunning)
            return;
        const bool hadExternalOperation = m_externalOperation;
        QString detected;
        bool stopped = false;
        qint64 detectedPid = 0;
        const QStringList markers{
            m_projectDirectory + QStringLiteral("/scripts/build-iso.sh"),
            m_projectDirectory + QStringLiteral("/build/iso-profile"),
            m_projectDirectory + QStringLiteral("/scripts/build-desktop-package.sh"),
            m_projectDirectory + QStringLiteral("/scripts/publish-repository.sh"),
            m_projectDirectory + QStringLiteral("/scripts/publish-iso-sourceforge.sh")};
        const QRegularExpression processLine(QStringLiteral("^\\s*(\\S+)\\s+(\\d+)\\s+(.*)$"));
        const QString processes = runCapture(
            QStringLiteral("ps"),
            {QStringLiteral("-eo"), QStringLiteral("stat=,pid=,args=")});
        for (const QString &line : processes.split('\n')) {
            const QRegularExpressionMatch match = processLine.match(line);
            if (!match.hasMatch())
                continue;
            for (const QString &marker : markers) {
                if (!line.contains(marker))
                    continue;
                detected = QFileInfo(marker).completeBaseName();
                stopped = match.captured(1).startsWith(QLatin1Char('T'));
                detectedPid = match.captured(2).toLongLong();
                break;
            }
            if (!detected.isEmpty())
                break;
        }
        m_externalOperation = !detected.isEmpty();
        m_externalStopped = stopped;
        m_externalPid = detectedPid;
        if (m_externalOperation) {
            if (lineIsIsoOperation(detected)) {
                m_currentAction = QStringLiteral("build-iso");
                m_operationTitle->setText(QStringLiteral("Сборка ISO — внешний процесс"));
                setPhase(QStringLiteral("checks"), QStringLiteral("done"));
                setPhase(QStringLiteral("cleanup"), QStringLiteral("done"));
                setPhase(QStringLiteral("profile"), QStringLiteral("done"));
                setPhase(QStringLiteral("packages"), QStringLiteral("running"));
                syncPackageCache();
                if (!hadExternalOperation) {
                    m_operationTabs->setCurrentIndex(0);
                    m_pages->setCurrentWidget(m_operationPage);
                }
            }
            m_activityBadge->setProperty("warning", true);
            m_activityBadge->setText(stopped ? QStringLiteral("● Сборка приостановлена · Управление")
                                             : QStringLiteral("● Операция выполняется"));
            m_activityBadge->setToolTip(QStringLiteral("Обнаружен внешний процесс: %1").arg(detected));
        } else {
            m_activityBadge->setProperty("warning", false);
            m_activityBadge->setText(QStringLiteral("● Готов к работе"));
            m_activityBadge->setToolTip({});
        }
        m_activityBadge->style()->unpolish(m_activityBadge);
        m_activityBadge->style()->polish(m_activityBadge);
        m_resumeExternalButton->setVisible(m_externalOperation && m_externalStopped);
        m_stopExternalButton->setVisible(m_externalOperation);
        updateBusyState(false);
    }

    void applyStyle()
    {
        qApp->setStyle(QStringLiteral("Fusion"));
        qApp->setStyleSheet(QStringLiteral(R"CSS(
            * { font-family: "Inter", "Noto Sans", sans-serif; font-size: 14px; }
            QMainWindow, QWidget { background: #111713; color: #dce5df; }
            QLabel { background: transparent; }
            QLabel#pageTitle { font-size: 30px; font-weight: 700; color: #eef5f0; }
            QLabel#sectionTitle { font-size: 17px; font-weight: 650; color: #e5eee8; }
            QLabel#muted, QLabel#stateCaption { color: #8fa198; }
            QLabel#stateCaption { font-size: 12px; }
            QLabel#stateValue { color: #e2eae5; font-size: 13px; }
            QPushButton#badge { background: #193c29; color: #9ee6ba; border: 0; border-radius: 14px; padding: 9px 13px; }
            QPushButton#badge:hover { background: #214d35; }
            QPushButton#badge[warning="true"] { background: #493918; color: #f0c875; }
            QPushButton#badge[warning="true"]:hover { background: #5a461d; }
            QPushButton#resumeButton { background: #9adbb4; color: #093d25; border: 0; border-radius: 11px; padding: 9px 13px; font-weight: 650; }
            QPushButton#resumeButton:hover { background: #b0e8c7; }
            QFrame#card, QFrame#consolePanel { background: #1a211d; border: 1px solid #2d3a32; border-radius: 16px; }
            QPushButton#actionButton { background: #1a211d; border: 1px solid #2d3a32; border-radius: 15px; padding: 13px 16px; text-align: left; color: #e1e9e4; font-weight: 600; }
            QPushButton#actionButton:hover { background: #222c26; border-color: #52725e; }
            QPushButton#actionButton:pressed { background: #29362e; }
            QPushButton#actionButton[primary="true"] { background: #9adbb4; color: #093d25; border-color: #9adbb4; }
            QPushButton#actionButton[primary="true"]:hover { background: #b0e8c7; }
            QPushButton#actionButton[danger="true"] { color: #f1b2ad; }
            QPushButton#actionButton:disabled { color: #65716a; background: #171c19; border-color: #252d28; }
            QPushButton#smallButton, QPushButton#dangerButton, QToolButton#iconButton { background: #202923; border: 1px solid #35443a; border-radius: 11px; padding: 9px 12px; color: #cfe0d5; }
            QPushButton#smallButton:hover, QToolButton#iconButton:hover { background: #29362e; }
            QPushButton#dangerButton { color: #f2aaa5; border-color: #6b3e3b; }
            QToolButton#iconButton { padding: 8px; }
            QLabel#phase { background: #161d19; border: 1px solid #2b3730; border-radius: 11px; padding: 8px 11px; color: #89968e; }
            QLabel#phase[state="running"] { background: #183324; border-color: #4c8b64; color: #a8e6bd; }
            QLabel#phase[state="done"] { background: #152a1e; border-color: #28553a; color: #8ed9aa; }
            QLabel#phase[state="failed"] { background: #351b1b; border-color: #713c39; color: #f0a39d; }
            QLabel#packageSummary { background: #17231c; border-radius: 10px; padding: 10px 12px; color: #b8c9bf; }
            QTabWidget#operationTabs::pane { border: 0; background: transparent; }
            QTabBar::tab { background: #18201b; color: #95a49b; border-radius: 9px; padding: 8px 14px; margin-right: 5px; }
            QTabBar::tab:selected { background: #294334; color: #b7e7c8; }
            QLineEdit { background: #101612; border: 1px solid #34443a; border-radius: 10px; padding: 8px 11px; color: #dbe7df; }
            QTreeWidget { background: #0f1511; alternate-background-color: #131b16; border: 1px solid #29372f; border-radius: 10px; color: #cbd8d0; outline: 0; }
            QTreeWidget::item { min-height: 25px; }
            QTreeWidget::item:selected { background: #294334; }
            QHeaderView::section { background: #1a241e; color: #aebdb4; border: 0; padding: 7px; }
            QPlainTextEdit#console { background: #0c110e; border: 0; border-radius: 10px; color: #cbd8d0; font-family: "JetBrains Mono", "Noto Sans Mono", monospace; font-size: 12px; padding: 9px; selection-background-color: #35634a; }
            QListWidget#logs { background: #1a211d; border: 1px solid #2d3a32; border-radius: 14px; padding: 5px; outline: none; }
            QListWidget#logs::item { border-radius: 9px; padding: 8px; color: #bdcbc2; }
            QListWidget#logs::item:hover, QListWidget#logs::item:selected { background: #263229; color: #e9f2ec; }
            QProgressBar { background: #263029; border: 0; border-radius: 3px; height: 6px; }
            QProgressBar::chunk { background: #95dcae; border-radius: 3px; }
            QScrollArea, QSplitter { border: 0; background: transparent; }
            QScrollBar:vertical { background: transparent; width: 9px; margin: 2px; }
            QScrollBar::handle:vertical { background: #3a493f; border-radius: 4px; min-height: 28px; }
            QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical { height: 0; }
            QMessageBox, QInputDialog { background: #171e1a; }
        )CSS"));
    }

    QString m_projectDirectory;
    QString m_backend;
    QString m_logDirectory;
    QProcess m_process;
    QTimer m_clock;
    QTimer m_stateRefresh;
    QElapsedTimer m_elapsed;
    QString m_currentTitle;
    QString m_currentAction;
    QString m_outputBuffer;
    bool m_cancelRequested = false;
    bool m_externalOperation = false;
    bool m_externalStopped = false;
    qint64 m_externalPid = 0;
    QList<QPushButton *> m_actionButtons;
    QHash<QString, QLabel *> m_phaseLabels;
    QHash<QString, QTreeWidgetItem *> m_packageItems;
    QHash<QString, QTreeWidgetItem *> m_packageGroups;
    QPushButton *m_activityBadge = nullptr;
    QPushButton *m_resumeExternalButton = nullptr;
    QPushButton *m_stopExternalButton = nullptr;
    QLabel *m_versionLabel = nullptr;
    QLabel *m_gitLabel = nullptr;
    QLabel *m_isoLabel = nullptr;
    QLabel *m_packageLabel = nullptr;
    QListWidget *m_logs = nullptr;
    QLabel *m_operationTitle = nullptr;
    QLabel *m_elapsedLabel = nullptr;
    QProgressBar *m_progress = nullptr;
    QPushButton *m_cancelButton = nullptr;
    QStackedWidget *m_pages = nullptr;
    QWidget *m_dashboardPage = nullptr;
    QWidget *m_operationPage = nullptr;
    QTabWidget *m_operationTabs = nullptr;
    QLabel *m_packageSummary = nullptr;
    QLineEdit *m_packageFilter = nullptr;
    QTreeWidget *m_packageTree = nullptr;
    QPlainTextEdit *m_console = nullptr;
};

int main(int argc, char *argv[])
{
    QApplication application(argc, argv);
    application.setApplicationName(QStringLiteral("KaskadOS Build Manager"));
    application.setOrganizationName(QStringLiteral("KaskadOS"));

    QString projectDirectory = QDir::currentPath();
    const QStringList arguments = application.arguments();
    const int projectIndex = arguments.indexOf(QStringLiteral("--project"));
    if (projectIndex >= 0 && projectIndex + 1 < arguments.size())
        projectDirectory = QDir(arguments[projectIndex + 1]).absolutePath();

    if (!QFileInfo::exists(projectDirectory + QStringLiteral("/kaskados-manager.sh"))) {
        QMessageBox::critical(nullptr, QStringLiteral("Проект не найден"),
                              QStringLiteral("Не удалось найти kaskados-manager.sh в %1").arg(projectDirectory));
        return 2;
    }

    ManagerWindow window(projectDirectory);
    window.show();

    const int screenshotIndex = arguments.indexOf(QStringLiteral("--screenshot"));
    if (screenshotIndex >= 0 && screenshotIndex + 1 < arguments.size()) {
        const QString screenshotPath = arguments[screenshotIndex + 1];
        QTimer::singleShot(500, &application, [&application, &window, screenshotPath] {
            const bool saved = window.grab().save(screenshotPath);
            application.exit(saved ? 0 : 3);
        });
    }
    return application.exec();
}
