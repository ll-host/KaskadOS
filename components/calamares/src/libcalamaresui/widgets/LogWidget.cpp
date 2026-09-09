/* === This file is part of Calamares - <https://calamares.io> ===
 *
 *   SPDX-FileCopyrightText: 2022 Bob van der Linden <bobvanderlinden@gmail.com>
 *   SPDX-License-Identifier: GPL-3.0-or-later
 *
 *   Calamares is Free Software: see the License-Identifier above.
 *
 */

#include "LogWidget.h"

#include "utils/Logger.h"

#include <QFile>
#include <QScrollBar>
#include <QStackedLayout>
#include <QTextCursor>
#include <QTextStream>
#include <QThread>

namespace Calamares
{

LogThread::LogThread( QObject* parent )
    : QThread( parent )
{
}

LogThread::~LogThread()
{
    quit();
    requestInterruption();
    wait();
}

void
LogThread::run()
{
    const auto filePath = Logger::logFile();

    qint64 lastPosition = 0;

    while ( !QThread::currentThread()->isInterruptionRequested() )
    {
        QFile file( filePath );

        qint64 fileSize = file.size();
        // Check whether the file size has changed since last time
        // we read the file.
        if ( lastPosition != fileSize && file.open( QFile::ReadOnly | QFile::Text ) )
        {

            // Start reading at the position we ended up last time we read the file.
            file.seek( lastPosition );

            QTextStream in( &file );
            auto chunk = in.readAll();
            qint64 newPosition = in.pos();

            lastPosition = newPosition;

            Q_EMIT onLogChunk( chunk );
        }
        QThread::msleep( 100 );
    }
}

LogWidget::LogWidget( QWidget* parent )
    : QWidget( parent )
    , m_text( new QPlainTextEdit )
    , m_log_thread( this )
{
    auto layout = new QStackedLayout( this );
    setLayout( layout );

    m_text->setReadOnly( true );
    m_text->setObjectName( "installation-log" );
    m_text->setPlaceholderText( tr( "Здесь появится подробный ход установки." ) );
    m_text->setVerticalScrollBarPolicy( Qt::ScrollBarPolicy::ScrollBarAlwaysOn );

    QFont monospaceFont( "monospace" );
    monospaceFont.setStyleHint( QFont::Monospace );
    m_text->setFont( monospaceFont );

    layout->addWidget( m_text );

    connect( &m_log_thread, &LogThread::onLogChunk, this, &LogWidget::handleLogChunk );
}

void
LogWidget::handleLogChunk( const QString& logChunk )
{
    m_text->moveCursor( QTextCursor::End );
    m_text->insertPlainText( logChunk );
    m_text->verticalScrollBar()->setValue( m_text->verticalScrollBar()->maximum() );
}

void
LogWidget::start()
{
    if ( m_log_thread.isRunning() )
    {
        m_log_thread.requestInterruption();
        m_log_thread.wait();
    }

    m_text->clear();
    m_log_thread.start( QThread::LowestPriority );
}

void
LogWidget::stop()
{
    if ( m_log_thread.isRunning() )
    {
        m_log_thread.requestInterruption();
        m_log_thread.wait();
    }
}


}  // namespace Calamares
