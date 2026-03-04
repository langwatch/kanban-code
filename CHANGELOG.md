# Changelog

## [0.1.14](https://github.com/langwatch/kanban-code/compare/v0.1.13...v0.1.14) (2026-03-04)


### Features

* rename clawd helper to kanban-code-active-session ([e6843a4](https://github.com/langwatch/kanban-code/commit/e6843a45c8186abf75083b6ffa4d36d698b888f0)), closes [#16](https://github.com/langwatch/kanban-code/issues/16)

## [0.1.13](https://github.com/langwatch/kanban-code/compare/v0.1.12...v0.1.13) (2026-03-04)


### Features

* add kanbancode:// deep links for Pushover notification taps ([cd4504a](https://github.com/langwatch/kanban-code/commit/cd4504a1a465cff3a721c95e9b35a3de147775aa))
* drag folders from Finder to create projects ([7feec20](https://github.com/langwatch/kanban-code/commit/7feec205e34bfa284cd3f3eaf14de916953f4a20))
* queued prompts with auto-send on Claude stop ([97f61c2](https://github.com/langwatch/kanban-code/commit/97f61c255e5c89baae3dc260796f70359c48d377))


### Bug Fixes

* cap prompt editor height to prevent text overflow in dialogs ([9d7bf8d](https://github.com/langwatch/kanban-code/commit/9d7bf8df1023560b2d410cb5c7d7035eb641727e))

## [0.1.12](https://github.com/langwatch/kanban-code/compare/v0.1.11...v0.1.12) (2026-03-04)


### Bug Fixes

* kill orphaned clawd processes to keep Amphetamine in sync ([1ae6fb3](https://github.com/langwatch/kanban-code/commit/1ae6fb3b009b94fc889a96f5ed57fb573df6df52))
* replace GNU `timeout` with perl-based alternative in remote shell ([e41d5cd](https://github.com/langwatch/kanban-code/commit/e41d5cd0c5a038aedf53c02dc2e5108e878090f4))
* replace GNU timeout with perl-based alternative in remote shell ([1c3ef11](https://github.com/langwatch/kanban-code/commit/1c3ef1114ffb48953b8e9b1e7d81d460068bfef5))
* use CLEAN instead of MERGEABLE for merge state check, prevent button wrapping ([3c62ab7](https://github.com/langwatch/kanban-code/commit/3c62ab7693784708fb314e10e944cf95a1fb09b2))

## [0.1.11](https://github.com/langwatch/kanban-code/compare/v0.1.10...v0.1.11) (2026-03-04)


### Features

* add in-app PR merge button via gh CLI ([5587a35](https://github.com/langwatch/kanban-code/commit/5587a355f2fac6040542e166f295104746664d1b))
* configurable merge command with squash + delete-branch default ([6dadad9](https://github.com/langwatch/kanban-code/commit/6dadad9dd534ebc7f5962a98453ad99d30c2da98))
* detect merge eligibility via GitHub mergeStateStatus ([8f44d27](https://github.com/langwatch/kanban-code/commit/8f44d27365d33d49519d20a20d2459e2a89c76e6))
* per-PR dismissal and manual PR linking ([3ab9c88](https://github.com/langwatch/kanban-code/commit/3ab9c88da6c963bcf244539a41f1156f83207312))
* show unresolved comments on PR badge and add merge button ([5baba1f](https://github.com/langwatch/kanban-code/commit/5baba1f677aa9be7a382955a49ad5ad510464c82))


### Bug Fixes

* add onPRMerged to CardDetailView explicit init ([b90d0ad](https://github.com/langwatch/kanban-code/commit/b90d0ad761bcffdf467fad79603aa18cc4b0bd76))
* detect PR approval when reviewDecision is empty ([f36a008](https://github.com/langwatch/kanban-code/commit/f36a008a6f894a182dd8a9dbd4904f80946f2cc8))
* handle missing mergeCommand in settings JSON to prevent data loss ([635b9ef](https://github.com/langwatch/kanban-code/commit/635b9ef12dccd1ddcc95c6f90fb3afa121385684))
* handle partial merge failures and update card status instantly ([e4d9f87](https://github.com/langwatch/kanban-code/commit/e4d9f8789804c8a94c155ee9472ed1d799b61446))
* kill stale tmux session on resume instead of reusing it ([31c54af](https://github.com/langwatch/kanban-code/commit/31c54afa03ef3a86c777d62ad55e4cb014009600))
* set isRemote on resume and add mutagen flush + uname preamble ([716435b](https://github.com/langwatch/kanban-code/commit/716435b6dcd48dac24984c27ef97d8cb3edcd43e))

## [0.1.10](https://github.com/langwatch/kanban-code/compare/v0.1.9...v0.1.10) (2026-03-04)


### Bug Fixes

* consistent matching, reverse numbering, and stable scroll for history search ([21cbc79](https://github.com/langwatch/kanban-code/commit/21cbc7913de0686ba3c013a513c549b4cd23e34e))
* don't forward modifier keys or Esc from tmux scroll mode ([6931d61](https://github.com/langwatch/kanban-code/commit/6931d61f15a8a742752544e4581757409fd77049))
* SessionStart triggering in-progress and add streaming history search ([4a50f20](https://github.com/langwatch/kanban-code/commit/4a50f2029405adeb89bf0f4d203da8b58a9b25e4))


### Performance

* chunk large terminal data to avoid blocking main thread ([ce9305f](https://github.com/langwatch/kanban-code/commit/ce9305fdc88baf9fc9bdab67ecfe0f616430fee6))

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
