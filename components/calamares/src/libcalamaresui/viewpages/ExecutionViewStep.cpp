/* === This file is part of Calamares - <https://calamares.io> ===
 *
 *   SPDX-FileCopyrightText: 2014 Aurélien Gâteau <agateau@kde.org>
 *   SPDX-FileCopyrightText: 2014-2015 Teo Mrnjavac <teo@kde.org>
 *   SPDX-FileCopyrightText: 2018 Adriaan de Groot <groot@kde.org>
 *   SPDX-License-Identifier: GPL-3.0-or-later
 *
 *   Calamares is Free Software: see the License-Identifier above.
 *
 */

#include "ExecutionViewStep.h"

#include "Slideshow.h"

#include "Branding.h"
#include "CalamaresConfig.h"
#include "Job.h"
#include "JobQueue.h"
#include "Settings.h"
#include "ViewManager.h"
#include "modulesystem/Module.h"
#include "modulesystem/ModuleManager.h"
#include "utils/Dirs.h"
#include "utils/Gui.h"
#include "utils/Logger.h"
#include "utils/Retranslator.h"
#include "widgets/LogWidget.h"

#include <QAction>
#include <QDir>
#include <QHBoxLayout>
#include <QLabel>
#include <QPainter>
#include <QPainterPath>
#include <QPlainTextEdit>
#include <QProgressBar>
#include <QTabBar>
#include <QTabWidget>
#include <QToolButton>
#include <QTimer>
#include <QVBoxLayout>

#include <cmath>

namespace
{

class WaveProgressBar : public QProgressBar
{
public:
    explicit WaveProgressBar( QWidget* parent = nullptr )
        : QProgressBar( parent )
    {
        setTextVisible( false );
        setFixedHeight( 18 );

        auto* animationTimer = new QTimer( this );
        QObject::connect( animationTimer, &QTimer::timeout, this, [ this ]() {
            m_phase += 0.35;
            update();
        } );
        animationTimer->start( 45 );
    }

protected:
    void paintEvent( QPaintEvent* ) override
    {
        QPainter painter( this );
        painter.setRenderHint( QPainter::Antialiasing );

        const QRectF track = QRectF( rect() ).adjusted( 1.0, 1.0, -1.0, -1.0 );
        QPainterPath trackPath;
        trackPath.addRoundedRect( track, track.height() / 2.0, track.height() / 2.0 );
        painter.fillPath( trackPath, QColor( "#303733" ) );

        const qreal range = maximum() - minimum();
        const qreal ratio = range > 0 ? qBound( 0.0, ( value() - minimum() ) / range, 1.0 ) : 0.0;
        const qreal fillWidth = track.width() * ratio;
        if ( fillWidth <= 0.0 )
        {
            return;
        }

        painter.save();
        painter.setClipPath( trackPath );

        if ( ratio >= 0.999 )
        {
            painter.fillPath( trackPath, QColor( "#9FE0B4" ) );
        }
        else
        {
            QPainterPath wave;
            const qreal waveTop = track.top() + 3.5;
            wave.moveTo( track.left(), track.bottom() );
            wave.lineTo( track.left(), waveTop + std::sin( m_phase ) * 2.0 );
            for ( qreal x = 0.0; x <= fillWidth; x += 2.0 )
            {
                const qreal y = waveTop + std::sin( x / 15.0 + m_phase ) * 2.0;
                wave.lineTo( track.left() + x, y );
            }
            wave.lineTo( track.left() + fillWidth, track.bottom() );
            wave.closeSubpath();
            painter.fillPath( wave, QColor( "#9FE0B4" ) );

            QPainterPath highlight;
            const qreal highlightTop = track.top() + 5.5;
            highlight.moveTo( track.left(), track.bottom() );
            highlight.lineTo( track.left(), highlightTop + std::sin( m_phase + 1.8 ) * 1.5 );
            for ( qreal x = 0.0; x <= fillWidth; x += 2.0 )
            {
                const qreal y = highlightTop + std::sin( x / 19.0 + m_phase + 1.8 ) * 1.5;
                highlight.lineTo( track.left() + x, y );
            }
            highlight.lineTo( track.left() + fillWidth, track.bottom() );
            highlight.closeSubpath();
            painter.fillPath( highlight, QColor( 139, 201, 160, 105 ) );
        }

        painter.restore();
    }

private:
    qreal m_phase = 0.0;
};

}  // namespace

static Calamares::Slideshow*
makeSlideshow( QWidget* parent )
{
    const int api = Calamares::Branding::instance()->slideshowAPI();
    switch ( api )
    {
    case -1:
        return new Calamares::SlideshowPictures( parent );
#ifdef WITH_QML
    case 1:
        [[fallthrough]];
    case 2:
        return new Calamares::SlideshowQML( parent );
#endif
    default:
        cWarning() << "Unknown Branding slideshow API" << api;
        return new Calamares::SlideshowPictures( parent );
    }
}

namespace Calamares
{

ExecutionViewStep::ExecutionViewStep( QObject* parent )
    : ViewStep( parent )
    , m_widget( new QWidget )
    , m_progressBar( new WaveProgressBar )
    , m_percentageLabel( new QLabel( QStringLiteral( "0%" ) ) )
    , m_label( new QLabel )
    , m_slideshow( makeSlideshow( m_widget ) )
    , m_tab_widget( new QTabWidget )
    , m_log_widget( new LogWidget )
    , m_toggleLogAction( nullptr )
{
    m_widget->setObjectName( "slideshow" );
    m_progressBar->setObjectName( "exec-progress" );
    m_percentageLabel->setObjectName( "exec-progress-percent" );
    m_percentageLabel->setAlignment( Qt::AlignRight | Qt::AlignVCenter );
    m_percentageLabel->setMinimumWidth( Calamares::defaultFontHeight() * 3 );
    m_label->setObjectName( "exec-message" );
    m_label->setWordWrap( true );

    QVBoxLayout* layout = new QVBoxLayout( m_widget );
    QHBoxLayout* progressLayout = new QHBoxLayout;
    QHBoxLayout* statusLayout = new QHBoxLayout;

    m_progressBar->setMaximum( 10000 );

    m_tab_widget->addTab( m_slideshow->widget(), tr( "О системе" ) );
    m_tab_widget->addTab( m_log_widget, tr( "Ход установки" ) );
    m_tab_widget->tabBar()->hide();

    layout->setContentsMargins( 18, 18, 18, 14 );
    layout->setSpacing( 12 );
    layout->addWidget( m_tab_widget, 1 );
    layout->addLayout( progressLayout );
    layout->addLayout( statusLayout );

    m_toggleLogAction = new QAction(
        Branding::instance()->image(
            { "utilities-log-viewer", "utilities-terminal", "text-x-log", "text-x-changelog", "preferences-log" },
            QSize( 32, 32 ) ),
        tr( "Показать ход установки" ),
        this );
    m_toggleLogAction->setToolTip( tr( "Переключиться между слайдами и журналом установки" ) );
    auto* toggleLogButton = new QToolButton;
    toggleLogButton->setObjectName( "exec-toggle-view" );
    toggleLogButton->setDefaultAction( m_toggleLogAction );
    connect( toggleLogButton, &QToolButton::clicked, this, &ExecutionViewStep::toggleLog );

    progressLayout->setSpacing( 12 );
    progressLayout->addWidget( m_progressBar, 1 );
    progressLayout->addWidget( m_percentageLabel );

    statusLayout->setSpacing( 16 );
    statusLayout->addWidget( m_label, 1 );
    statusLayout->addWidget( toggleLogButton, 0, Qt::AlignRight | Qt::AlignVCenter );

    connect( JobQueue::instance(), &JobQueue::progress, this, &ExecutionViewStep::updateFromJobQueue );
}

QString
ExecutionViewStep::prettyName() const
{
    return Calamares::Settings::instance()->isSetupMode() ? tr( "Set Up", "@label" ) : tr( "Install", "@label" );
}

QWidget*
ExecutionViewStep::widget()
{
    return m_widget;
}

void
ExecutionViewStep::next()
{
}

void
ExecutionViewStep::back()
{
}

bool
ExecutionViewStep::isNextEnabled() const
{
    return false;
}

bool
ExecutionViewStep::isBackEnabled() const
{
    return false;
}

bool
ExecutionViewStep::isAtBeginning() const
{
    return true;
}

bool
ExecutionViewStep::isAtEnd() const
{
    return !JobQueue::instance()->isRunning();
}

void
ExecutionViewStep::onActivate()
{
    m_slideshow->changeSlideShowState( Slideshow::Start );

    const auto instanceDescriptors = Calamares::Settings::instance()->moduleInstances();

    JobQueue* queue = JobQueue::instance();
    for ( const auto& instanceKey : m_jobInstanceKeys )
    {
        const auto& moduleDescriptor = Calamares::ModuleManager::instance()->moduleDescriptor( instanceKey );
        Calamares::Module* module = Calamares::ModuleManager::instance()->moduleInstance( instanceKey );

        const auto instanceDescriptor
            = std::find_if( instanceDescriptors.constBegin(),
                            instanceDescriptors.constEnd(),
                            [ = ]( const Calamares::InstanceDescription& d ) { return d.key() == instanceKey; } );
        int weight = moduleDescriptor.weight();
        if ( instanceDescriptor != instanceDescriptors.constEnd() && instanceDescriptor->explicitWeight() )
        {
            weight = instanceDescriptor->weight();
        }
        weight = qBound( 1, weight, 100 );
        if ( module )
        {
            auto jl = module->jobs();
            if ( module->isEmergency() )
            {
                for ( auto& j : jl )
                {
                    j->setEmergency( true );
                }
            }
            queue->enqueue( weight, jl );
        }
    }

    queue->start();
}

JobList
ExecutionViewStep::jobs() const
{
    return JobList();
}

void
ExecutionViewStep::appendJobModuleInstanceKey( const ModuleSystem::InstanceKey& instanceKey )
{
    m_jobInstanceKeys.append( instanceKey );
}

void
ExecutionViewStep::updateFromJobQueue( qreal percent, const QString& message )
{
    const int progressPercent = qBound( 0, qRound( percent * 100.0 ), 100 );
    m_progressBar->setValue( progressPercent * 100 );
    m_percentageLabel->setText( QStringLiteral( "%1%" ).arg( progressPercent ) );
    if ( !message.isEmpty() )
    {
        m_label->setText( message );
    }
}

void
ExecutionViewStep::toggleLog()
{
    const bool logBecomesVisible = m_tab_widget->currentIndex() == 0;  // ie. is not visible right now
    if ( logBecomesVisible )
    {
        m_log_widget->start();
    }
    else
    {
        m_log_widget->stop();
    }
    m_tab_widget->setCurrentIndex( logBecomesVisible ? 1 : 0 );
    m_toggleLogAction->setText( logBecomesVisible ? tr( "Вернуться к слайдам" ) : tr( "Показать ход установки" ) );
}

void
ExecutionViewStep::onLeave()
{
    m_log_widget->stop();
    m_slideshow->changeSlideShowState( Slideshow::Stop );
}

}  // namespace Calamares
