# Changelog

## [0.1.4](https://github.com/langwatch/kanban-code/compare/v0.1.3...v0.1.4) (2026-03-03)


### Features

* card merge via drag-and-drop ([e0ba4f7](https://github.com/langwatch/kanban-code/commit/e0ba4f771d736e4cae71d9b58eb95d5fcd3ec28b))
* dynamic editor discovery, pull-to-load history, and button hover feedback ([c21e616](https://github.com/langwatch/kanban-code/commit/c21e616bc6cbbb32e98397273926581eeb510cf9))
* improve link icons and add copy toast in card detail ([eb8d45c](https://github.com/langwatch/kanban-code/commit/eb8d45c897a804b71cd0e41d0f0500c0c3dbdb2c))


### Bug Fixes

* break up ContentView.body for release build type-checking ([36c5764](https://github.com/langwatch/kanban-code/commit/36c57643d563971ae9d67d33f320a55be2dde911))
* clear isLaunching immediately on launch/resume completion ([d677c2f](https://github.com/langwatch/kanban-code/commit/d677c2ff3262211d45dff6b4323af5ca1d12338a))
* further split ContentView.body for CI type-checker compatibility ([6286a3d](https://github.com/langwatch/kanban-code/commit/6286a3df1de1067e7724aeba6c9ccc1511bc6ad7))
* launch flow, project filter, prompt overflow, and worktree race condition ([fa7be45](https://github.com/langwatch/kanban-code/commit/fa7be452357cb8ddfded1ec7624bb6a5e1cf809e))
* load project list and cached cards instantly on startup ([040ad9a](https://github.com/langwatch/kanban-code/commit/040ad9ae8b9db6adccd7ed69032afef68582ba1d))
* make quit confirmation dialog reliable and instant ([a0edc5b](https://github.com/langwatch/kanban-code/commit/a0edc5b5c6fe35392685783caf33d30ce223042d))
* place SPM resource bundle at app root for Bundle.module discovery ([4e0efbc](https://github.com/langwatch/kanban-code/commit/4e0efbcc29140ce3ddaf1ab74797adbda496d410))
* replace SwiftUI Menu with NSMenu for actions button ([0c67955](https://github.com/langwatch/kanban-code/commit/0c6795521de9ccba28c6dad421f4002cf17dfdbb))
* resolve CLI binaries by absolute path for .app bundles ([1ee3f3e](https://github.com/langwatch/kanban-code/commit/1ee3f3ed010299be89cba8a62e772fce5b109987))
* scope PR lookups by repo to prevent cross-repo collisions ([746ac3b](https://github.com/langwatch/kanban-code/commit/746ac3be3baddc20732deb386e7770245a3c4e0e))
* sign binary only to avoid unsealed contents error from resource bundle ([879d276](https://github.com/langwatch/kanban-code/commit/879d276f8d90d24e773c2a90e91f181e6577eae6))
* skip codesign in CI to allow root-level SPM resource bundle ([43d61fa](https://github.com/langwatch/kanban-code/commit/43d61fa406c26c41df57dba38c11575bb57409ad))
* support manual release trigger in CI build job ([392dd8a](https://github.com/langwatch/kanban-code/commit/392dd8a4a3bc0adff667b2ce01fdb719909b91de))
* use Bundle.appResources for .app bundle resource discovery ([3a70c27](https://github.com/langwatch/kanban-code/commit/3a70c27dde08aeb6267fce7e5188640e399611f2))
* use macos-26 runner for Swift 6.2 compatibility ([a3458a4](https://github.com/langwatch/kanban-code/commit/a3458a4d8fd50ec26716c1f2bcbeeb5a2cab75d4))


### Documentation

* add download link to releases in README ([53bbf85](https://github.com/langwatch/kanban-code/commit/53bbf8516151e939193f1d0b7ec16183e781731e))

## [0.1.3](https://github.com/langwatch/kanban-code/compare/v0.1.2...v0.1.3) (2026-03-03)


### Features

* card merge via drag-and-drop ([e0ba4f7](https://github.com/langwatch/kanban-code/commit/e0ba4f771d736e4cae71d9b58eb95d5fcd3ec28b))
* improve link icons and add copy toast in card detail ([eb8d45c](https://github.com/langwatch/kanban-code/commit/eb8d45c897a804b71cd0e41d0f0500c0c3dbdb2c))


### Bug Fixes

* launch flow, project filter, prompt overflow, and worktree race condition ([fa7be45](https://github.com/langwatch/kanban-code/commit/fa7be452357cb8ddfded1ec7624bb6a5e1cf809e))
* load project list and cached cards instantly on startup ([040ad9a](https://github.com/langwatch/kanban-code/commit/040ad9ae8b9db6adccd7ed69032afef68582ba1d))
* make quit confirmation dialog reliable and instant ([a0edc5b](https://github.com/langwatch/kanban-code/commit/a0edc5b5c6fe35392685783caf33d30ce223042d))
* replace SwiftUI Menu with NSMenu for actions button ([0c67955](https://github.com/langwatch/kanban-code/commit/0c6795521de9ccba28c6dad421f4002cf17dfdbb))
* scope PR lookups by repo to prevent cross-repo collisions ([746ac3b](https://github.com/langwatch/kanban-code/commit/746ac3be3baddc20732deb386e7770245a3c4e0e))

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
