# Changelog

## [0.1.2](https://github.com/langwatch/kanban-code/compare/v0.1.1...v0.1.2) (2026-03-02)


### Features

* dynamic editor discovery, pull-to-load history, and button hover feedback ([c21e616](https://github.com/langwatch/kanban-code/commit/c21e616bc6cbbb32e98397273926581eeb510cf9))


### Bug Fixes

* clear isLaunching immediately on launch/resume completion ([d677c2f](https://github.com/langwatch/kanban-code/commit/d677c2ff3262211d45dff6b4323af5ca1d12338a))

## 0.1.1 (2026-03-02)

### Bug Fixes

* Fix CLI binary resolution for .app bundles — gh, tmux, mutagen, pandoc now found via absolute path lookup instead of PATH-dependent /usr/bin/env
* Fix terminal dying after ~2 seconds on resume — reconciler was clearing tmuxLink on cards mid-launch before the tmux session was visible
* Fix cached terminal frame to avoid SIGWINCH on reparent (zero-frame resize)
* Fast activity refresh path for immediate hook event processing

## 0.1.0 (2026-03-01)

Initial release.

### Features

* Kanban board for managing Claude Code sessions
* Launch, resume, and monitor Claude Code agents from a visual board
* Automatic session discovery and linking
* Remote server support with mutagen file sync
* Claude Code hook integration for real-time session tracking
* Fork and checkpoint session management
* Deep search across session transcripts
* Worktree-aware branch detection
* System tray with session notifications
