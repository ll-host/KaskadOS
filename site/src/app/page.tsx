const downloadUrl = "https://sourceforge.net/projects/kaskados-main/files/latest/download";
const repositoryUrl = "https://github.com/ll-host/KaskadOS";

const features = [
  {
    index: "01",
    title: "Собственное окружение",
    text: "Kaskad DE создаётся вместе с системой — от Wayland-композитора до панели, настроек и системных приложений.",
  },
  {
    index: "02",
    title: "Понятная установка",
    text: "Графический установщик проводит через основные решения и устанавливает систему без обязательного подключения к интернету.",
  },
  {
    index: "03",
    title: "Regalia внутри",
    text: "VPN-компонент разрабатывается как штатная часть рабочего окружения и не требует отдельной установки после первого входа.",
  },
  {
    index: "04",
    title: "Основа Arch Linux",
    text: "Свежая пакетная база Arch сочетается с продуманными настройками по умолчанию и графическим управлением системой.",
  },
];

export default function Home() {
  return (
    <main>
      <header className="site-header">
        <a className="brand" href="#top" aria-label="KaskadOS — на главную">
          <span className="brand-mark" aria-hidden="true">
            <img src="/kaskados-logo.png" alt="" />
          </span>
          <span>KaskadOS</span>
        </a>

        <nav aria-label="Основная навигация">
          <a href="#system">О системе</a>
          <a href="#inside">Что внутри</a>
          <a href="#development">Разработка</a>
        </nav>

        <a className="header-action" href={downloadUrl} target="_blank" rel="noreferrer">
          Скачать
          <span aria-hidden="true">↗</span>
        </a>
      </header>

      <section className="hero" id="top">
        <div className="hero-copy">
          <div className="eyebrow"><span /> Система на базе Arch Linux</div>
          <h1>Linux без<br /><em>лишнего шума.</em></h1>
          <p>
            KaskadOS объединяет собственное рабочее окружение, понятный
            установщик и системные инструменты в одну цельную систему.
          </p>

          <div className="hero-actions">
            <a className="button primary" href={downloadUrl} target="_blank" rel="noreferrer">
              Скачать KaskadOS
              <span aria-hidden="true">↓</span>
            </a>
            <a className="button secondary" href={repositoryUrl} target="_blank" rel="noreferrer">
              Открыть GitHub
              <span aria-hidden="true">↗</span>
            </a>
          </div>

          <div className="release-note">
            <span className="pulse" />
            <div>
              <strong>Проект активно развивается</strong>
              <small>Актуальные сборки публикуются на SourceForge</small>
            </div>
          </div>
        </div>

        <div className="hero-visual" aria-label="Стилизованный интерфейс KaskadOS">
          <div className="ambient ambient-one" />
          <div className="ambient ambient-two" />
          <div className="desktop-frame">
            <div className="desktop-topbar">
              <span className="mini-mark"><img src="/kaskados-logo.png" alt="" /></span>
              <span className="workspace-pill">Рабочее пространство 1</span>
              <span className="topbar-time">21:29</span>
            </div>
            <div className="desktop-canvas">
              <div className="welcome-panel">
                <span className="welcome-kicker">Добро пожаловать</span>
                <strong>KaskadOS</strong>
                <p>Всё нужное для работы уже на месте.</p>
                <div className="quick-row">
                  <span>Сеть</span>
                  <span>Обновления</span>
                  <span>Regalia</span>
                </div>
              </div>
              <div className="system-card card-a"><span>Система</span><strong>Готова</strong></div>
              <div className="system-card card-b"><span>Обновления</span><strong>Актуально</strong></div>
            </div>
            <div className="dock" aria-hidden="true"><i /><i /><i /><i /><i /></div>
          </div>
        </div>
      </section>

      <section className="manifesto" id="system">
        <p className="section-label">Зачем KaskadOS</p>
        <div className="manifesto-grid">
          <h2>Система должна помогать человеку, а не требовать от него помнить команды.</h2>
          <div>
            <p>
              Обычные задачи — установка, обновления, сеть и обслуживание —
              должны решаться через понятный интерфейс. Терминал остаётся
              инструментом, а не обязательным условием работы.
            </p>
            <div className="principles">
              <span><b>01</b> Разумные настройки по умолчанию</span>
              <span><b>02</b> Цельный интерфейс без случайных деталей</span>
              <span><b>03</b> Открытая разработка и прозрачные сборки</span>
            </div>
          </div>
        </div>
      </section>

      <section className="features" id="inside">
        <div className="section-heading">
          <div>
            <p className="section-label">Что внутри</p>
            <h2>Компоненты одной системы</h2>
          </div>
          <p>Каждая часть KaskadOS разрабатывается с учётом остальных, а не собирается как случайный набор пакетов.</p>
        </div>

        <div className="feature-grid">
          {features.map((feature) => (
            <article key={feature.index}>
              <span className="feature-index">{feature.index}</span>
              <h3>{feature.title}</h3>
              <p>{feature.text}</p>
              <span className="feature-line" />
            </article>
          ))}
        </div>
      </section>

      <section className="development" id="development">
        <div className="development-copy">
          <p className="section-label">Открытая разработка</p>
          <h2>Следи за тем, как строится KaskadOS.</h2>
          <p>
            Исходный код установщика, рабочего окружения и системных компонентов
            развивается в одном репозитории. Там можно следить за кодом и историей изменений.
          </p>
          <a className="button light" href={repositoryUrl} target="_blank" rel="noreferrer">
            Репозиторий на GitHub <span aria-hidden="true">↗</span>
          </a>
        </div>
        <div className="code-card" aria-hidden="true">
          <div className="code-card-head"><span /><span /><span /><b>kaskados</b></div>
          <pre><code><span className="muted">$</span> дерево проекта{"\n"}<span className="green">├──</span> components/calamares{"\n"}<span className="green">├──</span> components/macqueende{"\n"}<span className="green">├──</span> components/regalia{"\n"}<span className="green">├──</span> profile{"\n"}<span className="green">├──</span> scripts{"\n"}<span className="green">└──</span> site</code></pre>
        </div>
      </section>

      <section className="download">
        <div>
          <p className="section-label">Готов попробовать?</p>
          <h2>Скачай актуальную сборку KaskadOS.</h2>
        </div>
        <a className="button primary large" href={downloadUrl} target="_blank" rel="noreferrer">
          Скачать ISO <span aria-hidden="true">↓</span>
        </a>
      </section>

      <footer>
        <a className="brand" href="#top">
          <span className="brand-mark" aria-hidden="true"><img src="/kaskados-logo.png" alt="" /></span>
          <span>KaskadOS</span>
        </a>
        <p>Открытый дистрибутив на базе Arch Linux.</p>
        <a href={repositoryUrl} target="_blank" rel="noreferrer">GitHub ↗</a>
      </footer>
    </main>
  );
}
