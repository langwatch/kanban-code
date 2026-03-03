# Changelog

## [0.1.9](https://github.com/langwatch/kanban-code/compare/v0.1.8...v0.1.9) (2026-03-03)


### Features

* wrap clawd in .app bundle for Amphetamine detection ([b7dedf5](https://github.com/langwatch/kanban-code/commit/b7dedf5ce074fa34a0d66b0fdd93e3241d5044b8))

## [0.1.8](https://github.com/langwatch/kanban-code/compare/v0.1.7...v0.1.8) (2026-03-03)


### Features

* clean fork without worktree/PR baggage, option to fork to same worktree ([e3709a0](https://github.com/langwatch/kanban-code/commit/e3709a0f85aa17745d5584408a16c030546c7502))
* detect worktree branch changes during reconciliation ([87f620a](https://github.com/langwatch/kanban-code/commit/87f620a94cd0714cfbdffd5e7f9f674763769a72))
* scroll inside tmux via copy-mode on mouse wheel ([7100f2d](https://github.com/langwatch/kanban-code/commit/7100f2d6a0af38e6d402ff3340126b4d9b1adfe1))


### Bug Fixes

* activity detector redesign, fork worktree fix, search/terminal improvements ([7292231](https://github.com/langwatch/kanban-code/commit/729223199f0a431cc7713f3a63731bd9ce7ca4ea))
* clear stale PR link when worktree branch changes ([747d122](https://github.com/langwatch/kanban-code/commit/747d1228d913a353044f206713d6f54ed872879e))
* detect GitHub rate limit and show toast with 5-minute cooldown ([0f5c2a2](https://github.com/langwatch/kanban-code/commit/0f5c2a2309e4b183667f0882a176ae59aa4e1b3f))
* fork dialog from right-click, improved labels, smarter scroll exit ([baa67b6](https://github.com/langwatch/kanban-code/commit/baa67b6097184c0d5d7d38a0405d91f546b2e9ad))
* intercept scroll wheel events over tmux terminals via NSEvent monitor ([f04ab42](https://github.com/langwatch/kanban-code/commit/f04ab42030b94922dfda50707038c3e28f7fd022))
* label primary terminal tab "Shell" and avoid extra shell name collisions ([3bcc2fc](https://github.com/langwatch/kanban-code/commit/3bcc2fcebd3d1f38f510af0509a8d398274fd872))
* prevent cross-repo worktree flipping and read JSONL bottom-up ([0d429f8](https://github.com/langwatch/kanban-code/commit/0d429f8cac2ffa7f7fcdad534cb78315ea08bcaa))
* prevent tmux scroll mode key/scroll leaks to shell ([2b91f7a](https://github.com/langwatch/kanban-code/commit/2b91f7a697a8e53840efc8bd865919a0e144c9a9))
* respect PR dismiss override and show discovered branches in UI ([0699249](https://github.com/langwatch/kanban-code/commit/0699249199c17245896ae667823713bc35f7486f))
* shorten tmux copy-mode auto-exit to 1 second ([e202d2c](https://github.com/langwatch/kanban-code/commit/e202d2ca691bbfd05e19dee210f60d3f02a0ec4e))

## [0.1.7](https://github.com/langwatch/kanban-code/compare/v0.1.6...v0.1.7) (2026-03-03)


### Bug Fixes

* resolve user login shell environment and throttle gh API calls ([75f7381](https://github.com/langwatch/kanban-code/commit/75f73816d0bc8d483f6fa1a4eb8779b1557bd419))
* resolve user login shell environment and throttle gh API calls ([c62b49e](https://github.com/langwatch/kanban-code/commit/c62b49efb568b81598cc461035a5a4d2a6533448))

## [0.1.6](https://github.com/langwatch/kanban-code/compare/v0.1.5...v0.1.6) (2026-03-03)


### Features

* card merge via drag-and-drop ([e0ba4f7](https://github.com/langwatch/kanban-code/commit/e0ba4f771d736e4cae71d9b58eb95d5fcd3ec28b))
* dynamic editor discovery, pull-to-load history, and button hover feedback ([c21e616](https://github.com/langwatch/kanban-code/commit/c21e616bc6cbbb32e98397273926581eeb510cf9))
* improve link icons and add copy toast in card detail ([eb8d45c](https://github.com/langwatch/kanban-code/commit/eb8d45c897a804b71cd0e41d0f0500c0c3dbdb2c))
* independent terminal tabs, cancel launch, and wkhtmltopdf install fix ([9926262](https://github.com/langwatch/kanban-code/commit/992626243868c03f93836232632d1d64a00db551))


### Bug Fixes

* break up ContentView.body for release build type-checking ([36c5764](https://github.com/langwatch/kanban-code/commit/36c57643d563971ae9d67d33f320a55be2dde911))
* clear isLaunching immediately on launch/resume completion ([d677c2f](https://github.com/langwatch/kanban-code/commit/d677c2ff3262211d45dff6b4323af5ca1d12338a))
* decouple build from release-please to prevent skipped uploads ([5c26d1f](https://github.com/langwatch/kanban-code/commit/5c26d1f00a34ab0502d067d79442c627ab134682))
* expand binary search paths and show not-found banners in process manager ([1cbf6ce](https://github.com/langwatch/kanban-code/commit/1cbf6ce62c2c6ac9ff841927e8022411383fe51d))
* further split ContentView.body for CI type-checker compatibility ([6286a3d](https://github.com/langwatch/kanban-code/commit/6286a3df1de1067e7724aeba6c9ccc1511bc6ad7))
* launch flow, project filter, prompt overflow, and worktree race condition ([fa7be45](https://github.com/langwatch/kanban-code/commit/fa7be452357cb8ddfded1ec7624bb6a5e1cf809e))
* load project list and cached cards instantly on startup ([040ad9a](https://github.com/langwatch/kanban-code/commit/040ad9ae8b9db6adccd7ed69032afef68582ba1d))
* make quit confirmation dialog reliable and instant ([a0edc5b](https://github.com/langwatch/kanban-code/commit/a0edc5b5c6fe35392685783caf33d30ce223042d))
* place SPM resource bundle at app root for Bundle.module discovery ([4e0efbc](https://github.com/langwatch/kanban-code/commit/4e0efbcc29140ce3ddaf1ab74797adbda496d410))
* prepend cd to tmux send-keys to survive zshrc directory changes ([97f7337](https://github.com/langwatch/kanban-code/commit/97f7337989725cb77a05973234ea2a0851ff8652))
* remove duplicate release trigger that caused asset upload conflict ([0f3fbd6](https://github.com/langwatch/kanban-code/commit/0f3fbd634b2744f992b05928b020a9958693ed93))
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

## [0.1.5](https://github.com/langwatch/kanban-code/compare/v0.1.4...v0.1.5) (2026-03-03)


### Features

* independent terminal tabs, cancel launch, and wkhtmltopdf install fix ([9926262](https://github.com/langwatch/kanban-code/commit/992626243868c03f93836232632d1d64a00db551))


### Bug Fixes

* remove duplicate release trigger that caused asset upload conflict ([0f3fbd6](https://github.com/langwatch/kanban-code/commit/0f3fbd634b2744f992b05928b020a9958693ed93))

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
