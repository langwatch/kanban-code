# Changelog

## [0.1.19](https://github.com/langwatch/kanban-code/compare/v0.1.18...v0.1.19) (2026-03-14)


### Features

* add drag and drop to list view ([413c5bc](https://github.com/langwatch/kanban-code/commit/413c5bc96f456fe4236217c2fe3c9108a347a37e))
* add drag and drop to list view ([67dd18d](https://github.com/langwatch/kanban-code/commit/67dd18d6cd40cca0bf3618ca76b7814e01d6e758))
* add expanded mode for card detail inspector and image drag-and-drop ([5aec3f3](https://github.com/langwatch/kanban-code/commit/5aec3f32dda9e01bec6f59848656414413d61177))
* add Gemini hooks, enable/disable assistants, fix activity detection and notifications ([aa3e1b9](https://github.com/langwatch/kanban-code/commit/aa3e1b945ec45b090df3d32e533b8a4b7f50731b))
* add multi-coding-assistant support (Claude Code + Gemini CLI) ([24211bc](https://github.com/langwatch/kanban-code/commit/24211bc7597447b0a35c5328d8e99815e8af0760))
* centralize keyboard shortcuts with context-aware conditions ([b9c7bae](https://github.com/langwatch/kanban-code/commit/b9c7bae1f8c23b80fe4ee323793d343614bebd5e))
* Cmd+1-9 switches terminal tabs when drawer is open ([4c7c34b](https://github.com/langwatch/kanban-code/commit/4c7c34b8d2b4d033047757d7a45008ff1347e20e))
* Cmd+T new terminal, search badges, terminal flicker logging ([7f03cc7](https://github.com/langwatch/kanban-code/commit/7f03cc71ef256e32df54158a0628456c6b2e864a))
* improve terminal tab UX with double-click rename, drag reorder, and shell names ([baf4464](https://github.com/langwatch/kanban-code/commit/baf4464f9619cf4de2b55cd43d6aba06bb25f3ce))
* multi-coding-assistant support (Claude Code + Gemini CLI) ([d58dd50](https://github.com/langwatch/kanban-code/commit/d58dd503c7549d153127c2ca030ec81b3f6b8c4a))
* Parse inline markdown in session history assistant turns ([d0cbb9d](https://github.com/langwatch/kanban-code/commit/d0cbb9d6f4bf36d1e17e9fa4d0cd5ee092d92d7e))
* Parse inline markdown in session history assistant turns ([a77839f](https://github.com/langwatch/kanban-code/commit/a77839f56d8b5cd0493992602e286fa6550d5600))
* persist expanded mode, board split, and list section collapse ([bcaef03](https://github.com/langwatch/kanban-code/commit/bcaef035fc9cd5788294fed377c5c89344485b50))
* terminal tab folder names, Cmd+W close tab, Cmd+T focus ([4cb7884](https://github.com/langwatch/kanban-code/commit/4cb78847b2423f4737fee746a2363395ec280428))
* terminal tab rename, per-project remote toggle, worktree branch input ([b09dd97](https://github.com/langwatch/kanban-code/commit/b09dd97a5f30faf655981e6999701a188dcc2c68))
* transform search overlay into VS Code-style command palette ([ab35bea](https://github.com/langwatch/kanban-code/commit/ab35beaafd613e18880e008c6d6cedc2109eecb0))
* use custom icons for assistants and decouple assistant from card creation ([a30fc47](https://github.com/langwatch/kanban-code/commit/a30fc47db8a5060fb8b2e6c824f2bb618aef95a0))
* Windows port (Tauri + React) ([8c0a60e](https://github.com/langwatch/kanban-code/commit/8c0a60ef81e9db61ededaf6c44e2327a06367afd))
* **windows:** queued prompts, search, font size, issues, onboarding wizard ([72e435c](https://github.com/langwatch/kanban-code/commit/72e435ce4a632317749946c7bb079243101bcf9c))


### Bug Fixes

* archived cards no longer reappear after session discovery ([2d6e6c1](https://github.com/langwatch/kanban-code/commit/2d6e6c12ac8d572efbbcaa90f3b8f30d492dd04e))
* cards manually moved to backlog stay there despite activity ([6f950d7](https://github.com/langwatch/kanban-code/commit/6f950d7493647e06318c74efaf59f2825f52b20b))
* detect CLIs installed via nvm/volta/fnm and add assistants to settings ([ee47c3a](https://github.com/langwatch/kanban-code/commit/ee47c3a22ca6c1fc3836e3af6e8853730cc60052))
* filter Claude Code internal metadata from session display ([9ee4f8b](https://github.com/langwatch/kanban-code/commit/9ee4f8b75145c51093e1e0bb4df1627c999e4f57))
* Gemini prompt detection, error messages, and session linking ([2997c20](https://github.com/langwatch/kanban-code/commit/2997c20414b9872ccdbb611d32557c6148708688))
* Gemini remote execution and special character handling ([cad77b7](https://github.com/langwatch/kanban-code/commit/cad77b76bb3a9e1a7cef1c7cc54e36e3f57236d2))
* Gemini remote shell wrapper crashes and temp file warnings ([cdefbe0](https://github.com/langwatch/kanban-code/commit/cdefbe0d688e079c1264eb95bc49941834185926))
* make Gemini sparkle icon bolder and fix hardcoded prompt character ([1c57ce6](https://github.com/langwatch/kanban-code/commit/1c57ce655d0e161ca7c21ca98c75838aa59d122b))
* match Claude CLI's path encoding by also stripping dots ([08fd5c0](https://github.com/langwatch/kanban-code/commit/08fd5c04da4d74f495f309aa61702754bfde6853))
* move assistant picker to footer row in New Task dialog ([45902e0](https://github.com/langwatch/kanban-code/commit/45902e04f2726088226a9abeea48ce0339afbf24))
* parse inline markdown per-line to preserve multiline structure ([a791b5b](https://github.com/langwatch/kanban-code/commit/a791b5b4b12330b54edf9028b5ef32405166d65b))
* persist last-chosen assistant in New Task dialog ([e3cbdcb](https://github.com/langwatch/kanban-code/commit/e3cbdcb2cde9d9199462e8f621a47b3bf999df51))
* prevent cursor jumping to end in prompt editor during re-renders ([1616d9c](https://github.com/langwatch/kanban-code/commit/1616d9ca80cc9d2c676b11a4c66ce6b5059f30ff))
* prevent terminal flicker during background state updates ([4d591a3](https://github.com/langwatch/kanban-code/commit/4d591a3aff7f692968aa9495eea5a1145be7d818))
* queued prompt empty on restart and auto-send while editing ([6cb0499](https://github.com/langwatch/kanban-code/commit/6cb0499610d120c9dd765801221fd063a78acc44))
* resolve Cmd+Enter conflict between detail expand and deep search ([e8b2b7f](https://github.com/langwatch/kanban-code/commit/e8b2b7f61c961e8842a297ed0e743114ea1e741e))
* retry terminal focus after 500ms for heavy cards ([5e3ab18](https://github.com/langwatch/kanban-code/commit/5e3ab1801b5c7758ecbce1590cc0cc2f662fb113))
* selected project takes priority over last-used in new task dialog ([e22329d](https://github.com/langwatch/kanban-code/commit/e22329d0fe08cd4c7c45174b6e6e08f0efbeb8e0))
* swap order of path encoding to match Claude CLI (dots first, then slashes) ([1912958](https://github.com/langwatch/kanban-code/commit/1912958e81775d7a0ad5ff2b4c754966ed7d3aed))
* swap order of path encoding to match Claude CLI (slashes first, then dots) ([3237755](https://github.com/langwatch/kanban-code/commit/32377552d5e67f6d072388a07e689edd7931d1f2))
* sync status toolbar icon uses primary color when files in sync ([87e19b2](https://github.com/langwatch/kanban-code/commit/87e19b2e8e0bb518718f4337b4a24c0b6230a368))
* terminal scroll works in full area, not just upper portion ([a931436](https://github.com/langwatch/kanban-code/commit/a931436a4f14740a67e34d142721717352a2fe70))
* terminal tab rename uses dialog, add branch name field ([c110648](https://github.com/langwatch/kanban-code/commit/c110648f765ae2d44667854f7d244a654a0120d4))
* use assistant-specific icons everywhere and fix Gemini history loading ([e6bbad5](https://github.com/langwatch/kanban-code/commit/e6bbad579469260f08d79d753379f59336bb46a1))
* **windows:** GitHub-style thin white border lines in dark mode ([e5c329e](https://github.com/langwatch/kanban-code/commit/e5c329e857df301a65e119935575d2466905b2ec))
* **windows:** GitHub-style thin white border lines in dark mode ([ec89b35](https://github.com/langwatch/kanban-code/commit/ec89b351a55487352f8c31febd398a47526a0b13))


### Performance

* cache worktrees by mtime and pre-compute cards array ([5d6a46f](https://github.com/langwatch/kanban-code/commit/5d6a46feb08492eb4fd1e4e9f2b5e1d9e074529e))
* eliminate terminal flicker with time-budgeted batch feeding ([6dc9eb8](https://github.com/langwatch/kanban-code/commit/6dc9eb8aaf647fa359fb8b66f0f0f6c25a749c62))
* optimize reconciliation loop from ~1s to ~0.4s ([7c0a098](https://github.com/langwatch/kanban-code/commit/7c0a0986cd1ef9323a8aa938c13c085e5e2324e8))


### Documentation

* add Windows installation and usage instructions to README ([a0e0a95](https://github.com/langwatch/kanban-code/commit/a0e0a954a08f32f9c5103158e3905dde42346e69))

## [0.1.18](https://github.com/langwatch/kanban-code/compare/v0.1.17...v0.1.18) (2026-03-07)


### Features

* improve manual task prompt UX and image support ([23346ff](https://github.com/langwatch/kanban-code/commit/23346ff0c1f7e5a191edea2f27b0cd90691f09f9))
* open new task from lane double click ([596074f](https://github.com/langwatch/kanban-code/commit/596074f0648ddbb0fb073851e82b1c1694ebae1d))
* open new task from lane double click ([096033d](https://github.com/langwatch/kanban-code/commit/096033dadc2b63f8729f8ce52f98822f1113ce07))


### Bug Fixes

* add label selector to mutagen sync flush calls ([3653f66](https://github.com/langwatch/kanban-code/commit/3653f663c59c0a5489b125b485ee3645590e6852))
* add Start button and auto-create sync from remote shell ([293eaa9](https://github.com/langwatch/kanban-code/commit/293eaa994ac343fa2ad95669a6dd8f8a451b9adf))
* mutagen stop/reset/flush commands were silently failing ([fb5d3dc](https://github.com/langwatch/kanban-code/commit/fb5d3dcba753bf9d412b1cadc326d129ee32c0b1))
* stop ignoring VCS in mutagen sync ([e8855f9](https://github.com/langwatch/kanban-code/commit/e8855f9de4587902d1d184225088e50a9e25d28a))
* sync popover auto-resizes when content changes ([fd1f9ab](https://github.com/langwatch/kanban-code/commit/fd1f9abdcf96151a4e450ac975d597d7a3ad3454))
* sync popover text area uses fixed height ([892f89c](https://github.com/langwatch/kanban-code/commit/892f89ce56224931b26ece72429518af37b00159))
* sync status button padding, title case, adaptive polling ([85ff9b7](https://github.com/langwatch/kanban-code/commit/85ff9b73b47bd2a66cc163b0b3f3311acd470f24))
* sync status icon now reflects actual mutagen state ([f254988](https://github.com/langwatch/kanban-code/commit/f254988fc105f28c149ee18a019af31f57e7f2cd))
* toolbar padding and sync status polish ([ad942b4](https://github.com/langwatch/kanban-code/commit/ad942b496074ff9c55c14d5b78d3d58ae92ab1c6))

## [0.1.17](https://github.com/langwatch/kanban-code/compare/v0.1.16...v0.1.17) (2026-03-06)


### Features

* add cmd+click to open URLs in history view ([1e671f4](https://github.com/langwatch/kanban-code/commit/1e671f446de1edf10b6168a0c98d5a1585a0bd40))
* add drag-to-reorder for projects in settings ([235dcff](https://github.com/langwatch/kanban-code/commit/235dcff2f319c37d00cb03631ae973e7fbe02c13))
* **macos:** card reordering within same column ([7045925](https://github.com/langwatch/kanban-code/commit/704592552817db678b3d9a9e076ec610e2b66834))
* **macos:** card reordering within same column via drag-and-drop ([21695bd](https://github.com/langwatch/kanban-code/commit/21695bd71a22263821ca25680de8f994ca9ca921))
* paste images into prompts and send them to Claude Code via tmux ([ed7a24b](https://github.com/langwatch/kanban-code/commit/ed7a24b6bc78d2b5eceb8600cb7079de9af5b082))


### Bug Fixes

* merge button toast stuck and card not moving to done ([3f5557b](https://github.com/langwatch/kanban-code/commit/3f5557b37a82b4ee2e4ca36301d36eed3a8ac57c))
* remove terminal associations from cards when killing sessions on quit ([4d2aa74](https://github.com/langwatch/kanban-code/commit/4d2aa74c2e5f4ac1261508350e22bf0ea11b4ce0))
* use editor CLI to open worktree folders as project root ([ce54bb1](https://github.com/langwatch/kanban-code/commit/ce54bb198145920afbd679880920ba1886ed3812))
* use single mutagen sync session instead of one per project ([a97446c](https://github.com/langwatch/kanban-code/commit/a97446c37ae8dd8ba1871f4c267f418d36c69a8d))

## [0.1.16](https://github.com/langwatch/kanban-code/compare/v0.1.15...v0.1.16) (2026-03-05)


### Features

* add pushoverEnabled toggle to disable Pushover without deleting keys ([93083e8](https://github.com/langwatch/kanban-code/commit/93083e80de03a978ce68c559eb099eae4f5b121e))
* improve search relevance with word-start scoring, fuzzy initials, and recency boost ([2695a18](https://github.com/langwatch/kanban-code/commit/2695a185e91fd346a902b96220ecc6bf9fd07b1a))


### Bug Fixes

* relocate session file on resume when worktree was cleaned up ([9a33395](https://github.com/langwatch/kanban-code/commit/9a333952f9f4b1783ceb9555a43cd0c43f6398bc))

## [0.1.15](https://github.com/langwatch/kanban-code/compare/v0.1.14...v0.1.15) (2026-03-05)


### Features

* add configurable UI text size and terminal font size ([09e7465](https://github.com/langwatch/kanban-code/commit/09e7465ae9d35be22b206641325cf6d0a786c705)), closes [#19](https://github.com/langwatch/kanban-code/issues/19)
* fix worktree paths for remote sync, redesign merge button, add rate limit badges ([7de7f21](https://github.com/langwatch/kanban-code/commit/7de7f210c93a225523991b0e355c1e2b3222c3ca))


### Bug Fixes

* merge button never loads forever, hide for multiple open PRs ([9ba72f5](https://github.com/langwatch/kanban-code/commit/9ba72f574dc37bb838dfc3cdc6c79e5b3d0f100f))
* only fetch GitHub issues for projects with explicit filter ([604c5c1](https://github.com/langwatch/kanban-code/commit/604c5c1f2714216debfcebe9bc8d14af7b34e2f8))
* prevent cross-project branch matching in session reconciliation ([10b9b2f](https://github.com/langwatch/kanban-code/commit/10b9b2f5deb27eb12a01f02a220c0520a152ce3e))
* skip main repo checkout in worktree reconciliation ([b5cbd02](https://github.com/langwatch/kanban-code/commit/b5cbd029831c39059dad4dfb52f12284809e8bd6))
* split GitHub issues filter into separate args for gh CLI ([e4d9ece](https://github.com/langwatch/kanban-code/commit/e4d9ecefafefcb5e5e6a0aa69b86b2005350bea5))

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
