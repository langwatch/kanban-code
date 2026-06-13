# Kanban Code — краткая инструкция (по-русски)

Нативное приложение-канбан для управления сессиями Claude Code: карточки, tmux-сессии, git-worktree и PR в одном окне.

Этот файл кратко объясняет, как установить, запустить и протестировать проект, содержит примеры команд CLI и быстрый сценарий демонстрации.

Кому это нужно: разработчикам, которые хотят запускать несколько сессий Claude Code параллельно и контролировать каждую задачу как карточку на доске.

Коротко: карточка = сессия Claude + (опционально) worktree + tmux + PR/issue. Приложение автоматизирует создание worktree, управление tmux и отслеживание PR.

---

## Для чайников — пошаговая инструкция (очень просто)

1) Откройте терминал и перейдите в папку проекта:

```bash
cd ~/Projects/Canban/kanban-code
```

2) Проверьте, что у вас установлен Swift (macOS) и Node (для CLI):

```bash
swift --version   # macOS: должен быть Swift 6+
node --version    # Node.js для CLI (если планируете использовать CLI)
```

3) Запуск приложения на macOS (самый простой способ для начинающих):

- Если хотите просто запустить приложение из исходников, выполните:

```bash
make run-app
```

Если при запуске вы видите ошибку `make: *** No rule to make target 'run-app'`, значит вы не в той папке: сначала выполните `cd kanban-code` (см. шаг 1).

4) Запуск CLI локально (альтернатива, если GUI не нужен):

```bash
cd cli
npm install
node ./dist/kanban.js list   # или: npx node ./dist/kanban.js list
```

Если хотите установить удобную команду `kanban` в `~/.local/bin`, вернитесь в корень (`cd ..`) и выполните:

```bash
make install-cli
```

5) Частые проблемы и их простое решение:

- macOS блокирует запуск приложения: правый клик по приложению → "Open", затем System Settings → Privacy & Security → "Open Anyway".
- Ошибка отсутствия `gh` (GitHub CLI): установите через Homebrew `brew install gh`.
- Ошибка кодовой подписи (codesign): для локальной разработки обычно можно проигнорировать, если приложение запускается напрямую.

6) Если нужно — сохраните вывод команд в файл и пришлите мне его, я помогу с разбором:

```bash
make run-app 2>&1 | tee /tmp/kanban_run_output.txt
```


## Быстрый старт (демо за 5 минут)

Склонируйте репозиторий (у вас уже склонировано):

```bash
git clone https://github.com/langwatch/kanban-code.git
cd kanban-code
```

Запустить macOS-версию (на macOS 26, Swift 6):

```bash
make run-app
```

Для Windows (Tauri):

```bash
cd windows
npm install
npm run tauri dev
```

CLI (`kanban`) можно установить локально или использовать встроенный:

```bash
# установить в ~/.local/bin
make install-cli

# пример команд
kanban list
kanban show <card-id>
kanban capture <card-id>
kanban send <card-id> "hello"
```

---

## Установка и зависимости

- macOS: требуется Swift (в комплекте в Xcode/Swift toolchain), `tmux` (рекомендуется), опционально `gh` (GitHub CLI), `mutagen` для удалённого исполнения, Pushover для уведомлений.
- Windows: Node.js (v18+), Rust (для Tauri), опционально `gh`.

Приложение работает без большинства опциональных инструментов, но функциональность PR/issue/remote зависит от соответствующих утилит.

---

## Как тестировать локально

1. Убедитесь, что Swift установлен:

```bash
swift --version
```

2. Запустите тесты (модульные):

```bash
swift test
```

Примечание: интеграционные тесты требуют внешних инструментов/сессий (Claude/Gemini/gh), они могут быть помечены как пропущенные.

Если `swift test` долго собирает или пропускает тесты, сохраните вывод в файл для анализа:

```bash
swift test | tee /tmp/kanban_test_output.txt
```

---

## CLI — быстрые примеры

- Посмотреть все карточки (группировка по колонкам):

```bash
kanban list
```

- Показать карточку подробно:

```bash
kanban show card_2MtCMwX
```

- Отправить сообщение в сессию карточки (tmux):

```bash
kanban send card_2MtCMwX "Продолжай, пожалуйста"
```

- Захватить последние строки терминала карточки:

```bash
kanban capture card_2MtCMwX
```

Все команды поддерживают флаг `--json` для машинной обработки.

---

## Структура проекта (коротко)

- `Sources/` — Swift-код macOS-приложения и библиотек `KanbanCode`, `KanbanCodeCore`.
- `cli/` — Node.js/TypeScript реализация CLI (`kanban`).
- `windows/` — Tauri + React фронтенд для Windows.
- `Tests/` — тесты Swift для ядра.
- `spec/` — спецификации функций и сценариев.

---

## Архитектура (essentials)

- Чистая архитектура (port & adapter). Корневой поток: Action → Reducer → EffectHandler.
- В `KanbanCodeCore` лежат сущности (Session, Link, Worktree, PullRequest) и интерфейсы для адаптеров (Git, Tmux, Claude CLI).
- UI реагирует на одно централизованное состояние `AppState`.

---

## Быстрая демонстрация (сценарий для доклада)

1. Открыть приложение / запустить `make run-app`.
2. В `All Sessions` должна автоматически появиться обнаруженная сессия (если есть `~/.claude/projects`).
3. Выбрать карточку, открыть терминал внутри карточки и показать прикладную команду (например, запустить тесты в worktree).
4. Показать автоматическое перемещение карточки: Claude отправил PR → карточка в `In Review`.
5. Показать очистку worktree после слияния — карточка переходит в `Done`.

Для доклада можно подготовить заранее скриншоты из `assets/` (`assets/screenshot.webp`, `assets/productive-mode.webp`) или запустить небольшой live-demo с одной локальной Claude-сессией.

---

## Настройки (файл пользователя)

По умолчанию настройки хранятся в `~/.kanban-code/settings.json`.

Пример конфига:

```json
{
  "projects": [
    {"path": "/Users/you/Projects/my-app", "github": {"issueFilters": "assignee:@me state:open"}}
  ],
  "pushover": {"userKey": "...", "apiToken": "..."}
}
```

Карточки и связи хранятся в `~/.kanban-code/links.json`.

---

## Полезные команды разработки

- Запустить линтер/форматтер (если есть в CI): смотреть `Makefile` и `cli/package.json`.
- Собрать Windows dev: `cd windows && npm install && npm run tauri dev`.
- Установить локально CLI: `make install-cli`.

---

## Частые проблемы и отладка

- Если macOS блокирует приложение при первом запуске — правый клик → Open, затем System Settings → Privacy & Security → Open Anyway.
- Если отсутствуют сессии — убедитесь, что `~/.claude/projects/` содержит сессии или запустите Claude Code CLI и создайте одну.
- Интеграция с GitHub требует `gh` и токена, убедитесь, что `gh auth status` показывает авторизацию.

---

## Лицензия и вклад

Проект распространяется под AGPLv3. Файлы лицензии находятся в `LICENSE`.

Если нужно — могу перевести остальные документы (CONTRIBUTING, SPEC) и подготовить слайды на русском для презентации.

---

Автор: LangWatch (оригинальный репозиторий)
