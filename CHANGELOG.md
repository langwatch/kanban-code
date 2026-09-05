# Changelog

## [0.1.33](https://github.com/langwatch/kanban-code/compare/v0.1.32...v0.1.33) (2026-09-05)


### Features

* **activity:** keep a card working while its subagents are ([4319c7d](https://github.com/langwatch/kanban-code/commit/4319c7d0d6939b73e4316fd5dd854a4798838c7c))
* **agents:** a codex session carries the agent's name ([56a02c0](https://github.com/langwatch/kanban-code/commit/56a02c07cd65b05223529e8e54960cd993a9ceca))
* **agents:** a codex session carries the agent's name ([1eb32a3](https://github.com/langwatch/kanban-code/commit/1eb32a38a4df2faae0819fbcef14b28cdf63aea2))
* **agents:** name sessions in LangWatch, and stagger boot launches off the credential race ([143a23e](https://github.com/langwatch/kanban-code/commit/143a23e254efa0f32d3ecd66b98623356ca6537f))
* **agents:** name sessions in LangWatch, and stagger boot launches off the credential race ([3d54f35](https://github.com/langwatch/kanban-code/commit/3d54f3598163674934fdc20fd432270dd014c9d2))
* **app:** boxd mode in settings, launch dialogs and card lifecycle ([cfeaa51](https://github.com/langwatch/kanban-code/commit/cfeaa516a3f59f047ece5abe244f895a3290fe4e))
* **app:** title first in the new task dialog and a note on the boxd worktree ([adf870f](https://github.com/langwatch/kanban-code/commit/adf870fb99bbbb50ee93b29929d8e99321e41320))
* **boxd:** bring a machine back on focus, and keep the others in standby ([7a00170](https://github.com/langwatch/kanban-code/commit/7a00170db0030285dba12e7936e493f47d99d587))
* **boxd:** keep the assistant logins of the Mac and the machines in sync ([b2e220d](https://github.com/langwatch/kanban-code/commit/b2e220df15bf5187f9f341a8a4e1900240e0db6d))
* **boxd:** leave the machines running on quit and sleep, and keep the Mac awake for local sessions only ([736de8c](https://github.com/langwatch/kanban-code/commit/736de8cd16ea9432b81faf442872d72da971124c))
* **boxd:** machines park themselves, every pause becomes a stop ([fbf3298](https://github.com/langwatch/kanban-code/commit/fbf3298dd344ee35398ff84a0085c713b5fb57fd))
* **boxd:** one action to bring a paused machine back, over the transcript ([cea1d15](https://github.com/langwatch/kanban-code/commit/cea1d15bfcb34ec670212aa0f566f6ae4b51b8be))
* **boxd:** one idle window of 30 minutes for every machine ([742bc80](https://github.com/langwatch/kanban-code/commit/742bc80b0cae6cfa8dcdafc86c35bcda9d256702))
* **boxd:** open the card of a machine from the pill, and pay only for a look ([544dabd](https://github.com/langwatch/kanban-code/commit/544dabd18eed2f0fcbb16e8202ef671926cecf38))
* **boxd:** show a notice when a machine is destroyed ([429f4ee](https://github.com/langwatch/kanban-code/commit/429f4eef22c60906a18e760bd997fa34f9fb6254))
* **boxd:** stop the machine when the terminal tab is closed ([3601812](https://github.com/langwatch/kanban-code/commit/36018121496b80741eacfb1b696806e1b87f37af))
* **boxd:** tell an account switch and a login taken from a machine ([56bd3d0](https://github.com/langwatch/kanban-code/commit/56bd3d0a84920dd8fcd81c3f2d9fe6815fb65448))
* **boxd:** tell the terminal that the machine is coming back ([d2907b8](https://github.com/langwatch/kanban-code/commit/d2907b8e1c4a994cc32d64e8914133fd0b048c7c))
* **chat:** jump through history without parsing or mounting it ([a106871](https://github.com/langwatch/kanban-code/commit/a1068711db818f20bb78e92a1a0e474e2e409241))
* **chat:** stand a finished run of tool calls behind one line ([95d5cc2](https://github.com/langwatch/kanban-code/commit/95d5cc2319412da69b4be7963993ec6590c45cc3))
* **remote:** boxd machine core, bridge, mirror and supervisor ([4bb27ca](https://github.com/langwatch/kanban-code/commit/4bb27ca0d154b5b47c71d70d45c11060aa2b9cf3))
* **remote:** native boxd integration with a per-card cloud machine ([6ac38cb](https://github.com/langwatch/kanban-code/commit/6ac38cbbc5a5db8a371039af7e7c02edbc17040e))
* **shortcuts:** archive the open card with cmd+shift+A ([878160b](https://github.com/langwatch/kanban-code/commit/878160b15764c3e7ae6f20636253521d82a0136e))
* **shortcuts:** rename the open card with cmd+R ([a65f9e8](https://github.com/langwatch/kanban-code/commit/a65f9e8ba993da146ebf131689869826edd57b7a))
* **toolbar:** move the card tabs into the actions menu ([33a228f](https://github.com/langwatch/kanban-code/commit/33a228f7226abcc59f9f3a88b4834a058f09093d))
* **ui:** let the sidebar grow to 720pt ([77969b6](https://github.com/langwatch/kanban-code/commit/77969b63f5ff6dfbd672de5497dbaf2b55ad2e67))


### Bug Fixes

* **activity:** feed hook events to the detector in file order ([3d0fad4](https://github.com/langwatch/kanban-code/commit/3d0fad468221ca035edd565bb4a74cbb6def8ee6))
* **activity:** keep spinners live through slow reconciles, and survive timed-out shell commands ([2f42982](https://github.com/langwatch/kanban-code/commit/2f429825ab708c7fc376456224d32f7019283f90))
* **activity:** keep subagent tracking through a compaction ([bba2870](https://github.com/langwatch/kanban-code/commit/bba28701e5c0b36e811f312bdc2e66e833a4e76f))
* **agents:** a codex agent starts in a workspace it has never seen ([09d9ca2](https://github.com/langwatch/kanban-code/commit/09d9ca2fec1a0671ab1b2f8baf27eabed5369d35))
* **agents:** a codex agent starts in a workspace it has never seen ([b0f24d2](https://github.com/langwatch/kanban-code/commit/b0f24d22560d1a9dcb628143f03d72a804bc7d7a))
* **agents:** read the composer before deciding a name was taken ([4fbeb39](https://github.com/langwatch/kanban-code/commit/4fbeb39a343e47f2d3b59b9726f7a746b1634831))
* **app:** build the services once so the boxd supervisor reaches the real store, and let an early terminal find its machine ([a9e7372](https://github.com/langwatch/kanban-code/commit/a9e7372277610864d93311b4429ccc7789fcdf71))
* **app:** dismiss the dialogs with Escape and show every settings tab ([c995687](https://github.com/langwatch/kanban-code/commit/c995687e5c33f18994873bf3335f25f6310d4240))
* **app:** keep the launch overlay inside the terminal area, not under the toolbar ([8a47175](https://github.com/langwatch/kanban-code/commit/8a47175bed7aae16f2f244d7dcca7e8ea0f96597))
* **board:** a tall pinned rail scrolls instead of lifting the board ([dcc99d7](https://github.com/langwatch/kanban-code/commit/dcc99d73d24ab089e799fcc77789d326784f2efb))
* **boxd:** attach the terminal through boxd machine connect, create the worktree on the machine only, and stop the spinner of a paused machine ([5987772](https://github.com/langwatch/kanban-code/commit/5987772910bb0c97fe9b6ba5aec7591551f6c514))
* **boxd:** find the files to copy through git status, open new terminals on the machine, and keep a local resume off the machine ([0419f3f](https://github.com/langwatch/kanban-code/commit/0419f3fbc731c284e855dced2509d10cd63112c2))
* **boxd:** halt parked machines at Mac sleep and on quit ([c3a221f](https://github.com/langwatch/kanban-code/commit/c3a221f11668012c69d9d6eacc71d8a1fbbb14cd))
* **boxd:** keep a long launch alive, wait for the remote session, bound the quit pause and sweep orphan machines ([d209e16](https://github.com/langwatch/kanban-code/commit/d209e162b23fb10ca55ea42f97a6ec46986fa86c))
* **boxd:** keep isLaunching on a card on a machine until its launch reports, and leave an existing remote worktree alone on resume ([4ad33e2](https://github.com/langwatch/kanban-code/commit/4ad33e2e6c2db099910cc16234ed43ee4ef0e072))
* **boxd:** keep the terminal from waking a paused machine, and follow a machine resumed elsewhere ([f1569ed](https://github.com/langwatch/kanban-code/commit/f1569edd1fa348acfd3a470adb988ca51fccf6d7))
* **boxd:** keep the transcript skin inside the detail, not under the sidebar ([4d3d4e1](https://github.com/langwatch/kanban-code/commit/4d3d4e188255907f27a0b9398b07c7db5d2dbd8c))
* **boxd:** leave scroll mode with Esc and paste images into a session on a machine ([ea93bb5](https://github.com/langwatch/kanban-code/commit/ea93bb5f03ba34ee278977a3e54881e811fccee7))
* **boxd:** map hook event paths before the transcript arrives ([92729c0](https://github.com/langwatch/kanban-code/commit/92729c0fef67016bc684223182d34fc471137445))
* **boxd:** mirror a rewritten file whole and stamp the CLI with a digest of the bundle ([59d4008](https://github.com/langwatch/kanban-code/commit/59d40088d440091837e9281579d895f15cd1b589))
* **boxd:** open a new shell tab of a card on its machine ([6262d0a](https://github.com/langwatch/kanban-code/commit/6262d0a49ce5ef3ed8cb2f67b5dbe8b0600f9e12))
* **boxd:** open the launch dialog with the choice of the last run ([2bb2ab7](https://github.com/langwatch/kanban-code/commit/2bb2ab76e228dcfa7a877a66c870f9bcb69e5466))
* **boxd:** paste the image path after the upload, keep the native selection, and reconnect a running machine on paste or scroll ([fb63b10](https://github.com/langwatch/kanban-code/commit/fb63b105708543e16348257976b916da113fdd30))
* **boxd:** push transcript deltas, survive resume races, stop idle machines ([3abeffb](https://github.com/langwatch/kanban-code/commit/3abeffb568d7d79fdd7d1956baf9620fb1d1f891))
* **boxd:** random worktree name for an unnamed launch and pause on failed preparation ([0ce0757](https://github.com/langwatch/kanban-code/commit/0ce075725613234baa788ed0d543401e64ca09d3))
* **boxd:** read the pause marker before the terminal connects to a machine ([473cb24](https://github.com/langwatch/kanban-code/commit/473cb2459e0145aee33ce00f60346b72a3f5ad66))
* **boxd:** resume a card with a large transcript on its machine ([9d5a3b7](https://github.com/langwatch/kanban-code/commit/9d5a3b7c5f39a269084b9642f00860189243aeaf))
* **boxd:** retry the remote attach until the tmux session exists ([87f1352](https://github.com/langwatch/kanban-code/commit/87f135286adb927d81b9429f4158eb65bee1d10f))
* **boxd:** route CLI keys locally for local cards, drop stale compact steers ([813cb01](https://github.com/langwatch/kanban-code/commit/813cb015647a98c40a126c12a037cf19cb78c16b))
* **boxd:** scroll a session on a machine with the wheel ([41c58f8](https://github.com/langwatch/kanban-code/commit/41c58f8511c55bdcb11781499d0a7e5ebb12b3ee))
* **boxd:** stop a parked machine once, record outside tmux kills ([44bb5fd](https://github.com/langwatch/kanban-code/commit/44bb5fd2043351c0bf4548e7f4e6b05ed2dfc942))
* **chat:** draw a link in the link colour when the message has no block markdown ([15e32fd](https://github.com/langwatch/kanban-code/commit/15e32fd1cceb0780df61995e790adcf3cf5f02d9))
* **chat:** keep the whole clicked message on a checkpoint restore ([e0da045](https://github.com/langwatch/kanban-code/commit/e0da0452047ff3c0256e0132936d041d1d1a008c))
* **chat:** land a jump below the floating pill, not underneath it ([c8af904](https://github.com/langwatch/kanban-code/commit/c8af904d54709ae3a75e49d732a57545c18b65f6))
* **chat:** pay for each history load with a real scroll ([e9b692c](https://github.com/langwatch/kanban-code/commit/e9b692c06e003decc4f873555937a3df636f4878))
* **chat:** stop an expanded message drawing over the one below it ([b4b2582](https://github.com/langwatch/kanban-code/commit/b4b258212da76aa765e3fac8be8eb9f8b1dd0615))
* **chat:** stop history loads a card switch triggers on its own ([b460718](https://github.com/langwatch/kanban-code/commit/b460718d24c752e333c92f2de7eca2257b7f4aac))
* **chat:** stop sizing probes from freezing the chat feed ([9e90725](https://github.com/langwatch/kanban-code/commit/9e90725a19241811b19817ca3d3c18a94e6de4d3))
* **chat:** stop the idle blink and the load that stops at the top ([4cda740](https://github.com/langwatch/kanban-code/commit/4cda740a1fb0ec234bc26d81b55d3b92c1032dba))
* **cli:** stop scheduled prompts from concatenating in the composer ([a75a8dc](https://github.com/langwatch/kanban-code/commit/a75a8dc11cc757c2fbc2a9dbc444f9908414751d))
* **detail:** drop the link property rows from the card header ([1d74928](https://github.com/langwatch/kanban-code/commit/1d74928a68551a7be374f1a9d1877167ad4b682f))
* **diag:** notice tmux mass deaths across app restarts ([a17f1d9](https://github.com/langwatch/kanban-code/commit/a17f1d9095fb4995109d0a01bca2cc68a58c9c5b))
* **discovery:** find the pull requests a card worked on but never pushed ([09b5e1e](https://github.com/langwatch/kanban-code/commit/09b5e1ebf91dcf17350417a59d520556fd45dc36))
* **pr:** refresh a pull request in the repository it lives in ([87db565](https://github.com/langwatch/kanban-code/commit/87db565ba16393a41b5fbb089ad0035724390d56))
* **reconcile:** a launch takes only the session it started ([c73fe97](https://github.com/langwatch/kanban-code/commit/c73fe9757919af0d3c4a9934fd93cb61fb50d4b0))
* **reconciler:** stop the board from re-rendering every pass ([39f63ef](https://github.com/langwatch/kanban-code/commit/39f63efe71749a74631f9e027d1a0fdfff0f87ee))
* **self-compact:** drop a context warning the agent no longer needs ([f33e875](https://github.com/langwatch/kanban-code/commit/f33e875d99319f19d6ae995e313e03b7b779e7f5))
* **terminal:** make a link written by an agent clickable ([abfa2ab](https://github.com/langwatch/kanban-code/commit/abfa2abd1d9c84479119d6e941e1ff9ebb462916))
* **toolbar:** the sidebar's buttons do not double the detail's ([b92f647](https://github.com/langwatch/kanban-code/commit/b92f6475d9e1c092a5b8adf517b76ae8022870eb))
* **ui:** keep the machine banner off cards resumed locally ([d1140c3](https://github.com/langwatch/kanban-code/commit/d1140c3f674bc9a4ac6cdf3e58990b77c7106f65))
* **ui:** let Return confirm the destroy machine and remove worktree dialogs ([56217c0](https://github.com/langwatch/kanban-code/commit/56217c01c26fe7d85307001668ea68d8d2a3994c))
* **ui:** show a stop icon for stopped boxd machines ([b340a1b](https://github.com/langwatch/kanban-code/commit/b340a1b48e4b671291cd70757b70c1aac707c73f))


### Refactoring

* **agents:** name sessions through claude's own --name, drop the env var ([5321a81](https://github.com/langwatch/kanban-code/commit/5321a81bba50949ffda11bd2c59ca6e3079b97ec))
* **boxd:** name the machines kanban-&lt;repo&gt;-&lt;card&gt; and drop a needless await in the bridge reader ([f8a1c72](https://github.com/langwatch/kanban-code/commit/f8a1c72c8d1cee0336f058e792e437e94257f3d8))

## [0.1.32](https://github.com/langwatch/kanban-code/compare/v0.1.31...v0.1.32) (2026-08-09)


### Bug Fixes

* **terminal:** show IME/dictation marked text in the embedded terminal ([fcce2f6](https://github.com/langwatch/kanban-code/commit/fcce2f64c942432e43674143ddf050f96bf1497f))

## [0.1.31](https://github.com/langwatch/kanban-code/compare/v0.1.30...v0.1.31) (2026-08-09)


### Features

* add first-class subagents ([f4d4a85](https://github.com/langwatch/kanban-code/commit/f4d4a85ca1a08ba22629b398d59eabf34dc19d50))
* add first-class subagents ([8e749e3](https://github.com/langwatch/kanban-code/commit/8e749e37640dbdbf7c533ae204a7837a4f06a483))
* add per-subagent compact thresholds ([8ad6f5f](https://github.com/langwatch/kanban-code/commit/8ad6f5f4c0a94eb9b1461b542adb7c8fef7d5f01))
* **chat:** carry a text selection from one message into the next ([23cea10](https://github.com/langwatch/kanban-code/commit/23cea10b83b13a2b6a8fc5338591848713be10e9))
* **chat:** draw every message text row in one selectable text view ([11b0564](https://github.com/langwatch/kanban-code/commit/11b05643ce7ae3d1d3a3ab6bf91746c5e4cfd9b0))
* **chat:** give the chat composer the keyboard back, the way the terminal has it ([1974d5c](https://github.com/langwatch/kanban-code/commit/1974d5ca7b68e9173c7a8c730d2504721074eac5))
* **chat:** let a selection run through cards and channel messages ([35920d1](https://github.com/langwatch/kanban-code/commit/35920d1f76e2df39cf4393ada5e633e48e296193))
* **delivery:** steer, queue, and interrupt as first-class semantics ([69bb219](https://github.com/langwatch/kanban-code/commit/69bb219571397afb2222446e1567592257ba58d4))
* **diagnostics:** attribute memory pressure to tmux session process trees ([a2e7c17](https://github.com/langwatch/kanban-code/commit/a2e7c17d38a96833fb8f6df434edfc58b6d0119f))
* **markdown:** render markdown into one attributed string with real tables ([2f9197d](https://github.com/langwatch/kanban-code/commit/2f9197df22bb7de9195abebcd705dbf10c8480a1))
* **queue:** add a prompt history to the card menu ([b446b10](https://github.com/langwatch/kanban-code/commit/b446b1085ef9e1952c72afe7636730885be901d1))
* **queue:** journal every queued prompt before it can be lost ([2f03797](https://github.com/langwatch/kanban-code/commit/2f03797dcdcd7398b82d71039e6dd04bd25b95f8))
* **shortcuts:** make Cmd+P pin the selected card ([843b711](https://github.com/langwatch/kanban-code/commit/843b711ec53ca94a2dc0802a33ebfa963fa7fc4c))
* **subagent:** let a child ask for its own worktree ([ae0a8f0](https://github.com/langwatch/kanban-code/commit/ae0a8f09b52a11866a0d288e694dc6102171d5a5))
* **subagents:** escalate per-card compaction the same way as global ([b5bfff3](https://github.com/langwatch/kanban-code/commit/b5bfff36f3de040fa669ddaecf3b9f57d9fe4831))
* **subagents:** fork owned children and label parent DMs ([667aff6](https://github.com/langwatch/kanban-code/commit/667aff69181dee0e1d0fee10ac65a858ddfc7e57))


### Bug Fixes

* accumulated verified fixes from recent sessions ([d01cd10](https://github.com/langwatch/kanban-code/commit/d01cd1076b85ee30a4fb72f37ec8d1edc16ecf2c))
* **board:** centre the notice banner on the window ([b533d1f](https://github.com/langwatch/kanban-code/commit/b533d1f16119066e3e24e5b940e7e5cac0ebf034))
* **board:** make the notice banner readable over a terminal ([43bb7b3](https://github.com/langwatch/kanban-code/commit/43bb7b38cc06b0d6482f724ceca144f1aef55ce2))
* **board:** show session ended instead of tmux attach error after reboot ([c52695f](https://github.com/langwatch/kanban-code/commit/c52695fa71286020a9fa9a52fccb256914a0f3b7))
* **board:** stop good news arriving as a warning ([ffeb985](https://github.com/langwatch/kanban-code/commit/ffeb98569bafcf3b2ddefaf4fbdb2554469a9294))
* **chat:** cap system-style messages like every other block ([5e5f85b](https://github.com/langwatch/kanban-code/commit/5e5f85bd03fc31b628e676449d4b2238028a3bc5))
* **chat:** hold task notifications to the same column as every message ([096900f](https://github.com/langwatch/kanban-code/commit/096900fc57866f49c759b767598445725ef3c1da))
* **chat:** keep a table at the width it was measured at ([3e3301b](https://github.com/langwatch/kanban-code/commit/3e3301b3dbe4ddd418d7b14e41fd3ed9ba1cca69))
* **chat:** land the search on the match instead of near it ([4033035](https://github.com/langwatch/kanban-code/commit/4033035d4113850abe8de478fe37683ba38aca08))
* **chat:** make in-conversation search find and paint its match ([16c0480](https://github.com/langwatch/kanban-code/commit/16c0480515742656a2cfe9406b242e6584b6d104))
* **chat:** make search agree with the transcript on which turn is which ([237734c](https://github.com/langwatch/kanban-code/commit/237734cbaf3ba28b01b0f5f4ab75921d32d3d6db))
* **chat:** resolve repo[#123](https://github.com/langwatch/kanban-code/issues/123) references against the card's owner ([20d3a7d](https://github.com/langwatch/kanban-code/commit/20d3a7dd0482eb9328ee60f0786e1a7cc265d928))
* **chat:** stop a message with a table drawing over the one below it ([11637f3](https://github.com/langwatch/kanban-code/commit/11637f30163d443fa3f1d4759fe2abcd3389885d))
* **chat:** stop a restored draft from being thrown away on the next keystroke ([8abd6fd](https://github.com/langwatch/kanban-code/commit/8abd6fdd063914edb3af42792d8ec4cf1560061a))
* **codex:** make restore-to-turn actually truncate ([8102284](https://github.com/langwatch/kanban-code/commit/8102284b07c85eb4d06c262249c22ffe1311a00b))
* **diagnostics:** survive-the-night defenses after 28GB balloon incident ([bfafaf0](https://github.com/langwatch/kanban-code/commit/bfafaf02f2b6b0d81e132491cd1ac2cc6b905fb2))
* **gh:** group PR lookups by remote slug so worktrees stop multiplying GraphQL calls ([1249195](https://github.com/langwatch/kanban-code/commit/1249195893bdfd22c0408673dc0b0db59f5a8431))
* harden subagent workflows ([4de5046](https://github.com/langwatch/kanban-code/commit/4de5046d12328a93dcbabca55904934749c52652))
* **migration:** write message.model so claude --resume works ([bdda634](https://github.com/langwatch/kanban-code/commit/bdda634c8890164d7b729c13e2a1be38378e6838))
* preserve piped self-compact handoffs ([7ec472c](https://github.com/langwatch/kanban-code/commit/7ec472cc0f7c4ce7a76b8d6b48edd60b123ac9ea))
* **search:** put the quick palette back on an eager stack ([6b97180](https://github.com/langwatch/kanban-code/commit/6b9718014ffb7e2ed4b17b3e529aa38722691f01))
* **sessions:** resolve symlinks when encoding Claude project folders ([d086f45](https://github.com/langwatch/kanban-code/commit/d086f457b0903f0fd66a67cbc4f70f6a082b1280))
* **shell:** close the pipe descriptors every spawned command borrows ([5ff532a](https://github.com/langwatch/kanban-code/commit/5ff532a7482c9b89ffa487e6262b11dd4e0e36e6))
* **terminal:** don't glue soft-wrap boundaries in implicit links ([090070d](https://github.com/langwatch/kanban-code/commit/090070d22517b2659e4e3e24d81e12c6806cbbca))
* **terminal:** stop the terminal eating scrolls meant for the palette ([43c2dba](https://github.com/langwatch/kanban-code/commit/43c2dba3c9553b00ccaa340db85cb6f2bcddb8c0))
* **terminal:** trim URL punctuation; parse current codex rollouts ([4442098](https://github.com/langwatch/kanban-code/commit/44420986c94461c43275f40ca8da8962893990b4))
* **windows:** wrap pinnedCards Zustand selector in useShallow ([#139](https://github.com/langwatch/kanban-code/issues/139)) ([1db691f](https://github.com/langwatch/kanban-code/commit/1db691fd50b2a4af5d738ddc7540c3ca8ec3ca8b))


### Performance

* **search:** deliver each match as it lands instead of per batch ([5cfe872](https://github.com/langwatch/kanban-code/commit/5cfe872639e98a4e9ecc75c1bb3bb3e5ac83e740))
* **search:** open the quick palette on the frame it is asked for ([a25441f](https://github.com/langwatch/kanban-code/commit/a25441fe9fa4220abc28fbfa2aa761118ab5e359))
* **search:** read transcripts in blocks instead of byte by byte ([a17c51c](https://github.com/langwatch/kanban-code/commit/a17c51c27bd24450cd98f73cff2148e9a37a659b))
* **search:** stop scanning every transcript byte for every query ([1ab21c5](https://github.com/langwatch/kanban-code/commit/1ab21c571fccbf8766611fc5cbd8934d444c12ee))
* **search:** stop the quick palette indexing every card before it opens ([edcf5d2](https://github.com/langwatch/kanban-code/commit/edcf5d2c8fb789498bf6e28dba6857d252676a3c))
* **search:** stop the quick palette re-sorting the board on every render ([7b2fb70](https://github.com/langwatch/kanban-code/commit/7b2fb7039a70318db4967f577e63dd2731739947))


### Refactoring

* **gh:** extract PR lookup grouping into a tested pure helper ([503fabf](https://github.com/langwatch/kanban-code/commit/503fabf265476e4f44153a3e5aefbf32da7bfc41))

## [0.1.30](https://github.com/langwatch/kanban-code/compare/v0.1.29...v0.1.30) (2026-06-16)


### Features

* **app:** board auto-selects a room's channel via a focus-channel marker ([507826e](https://github.com/langwatch/kanban-code/commit/507826ec0c8eec18bc65c1288830b0433a7dfbde))
* **app:** board auto-selects a room's channel via a focus-channel marker ([9f6add7](https://github.com/langwatch/kanban-code/commit/9f6add7c5a11c2242c9749dfdff83736808807f2))
* **cli:** kanban launch --no-resume for fresh ephemeral agents ([8133764](https://github.com/langwatch/kanban-code/commit/81337642600d076246f5b5206d9624eb7db25b97))
* **slack:** post a 👀 ack on relay and delete it on the agent's first reply ([c512824](https://github.com/langwatch/kanban-code/commit/c5128247280eb1bc3eac077f6dbc6478181e1cf5))
* **windows:** add project switcher dropdown to board header ([0dd340b](https://github.com/langwatch/kanban-code/commit/0dd340b5183c0818a459aec527e37a327a1b8c9e))
* **windows:** add structured logging + verify Phase 0 baseline ([982e412](https://github.com/langwatch/kanban-code/commit/982e412cee1ace0f99dbef14806a5b17a48ccdfb))
* **windows:** APIService entity + per-card endpoint binding ([#130](https://github.com/langwatch/kanban-code/issues/130)) ([30eb132](https://github.com/langwatch/kanban-code/commit/30eb132127e6981db1cfc0cde9035458fe017fae))
* **windows:** app-wide font scaling (Ctrl+/-/0) and list view mode ([ccbd139](https://github.com/langwatch/kanban-code/commit/ccbd139218af3cc2348f3e0495d1cb90aec35a44))
* **windows:** BM25 deep transcript search wired into SearchOverlay ([db4a28f](https://github.com/langwatch/kanban-code/commit/db4a28f6c492633f648ecdef32b2925b2dfb9a6b))
* **windows:** browser keyboard shortcuts + reopen-last-closed ring ([#125](https://github.com/langwatch/kanban-code/issues/125) steps 5+6) ([#137](https://github.com/langwatch/kanban-code/issues/137)) ([816a860](https://github.com/langwatch/kanban-code/commit/816a86041a4de9545e8035e4c6792506751a7946))
* **windows:** browser tabs data layer + Tauri CRUD ([#125](https://github.com/langwatch/kanban-code/issues/125) step 1) ([#134](https://github.com/langwatch/kanban-code/issues/134)) ([10dc02d](https://github.com/langwatch/kanban-code/commit/10dc02dca4afacd16469d17e27d356f2e3bec244))
* **windows:** browser tabs UI shell — tab strip + URL bar + DnD reorder ([#125](https://github.com/langwatch/kanban-code/issues/125) step 2) ([#135](https://github.com/langwatch/kanban-code/issues/135)) ([b37f39f](https://github.com/langwatch/kanban-code/commit/b37f39f37810e0194eaed3b91c8c2aa5401f8d00))
* **windows:** card merge via drop-onto-card ([c8249a6](https://github.com/langwatch/kanban-code/commit/c8249a667650d1d26324adc9064fc197cc43c15d))
* **windows:** chat message actions — edit/delete/reactions/mentions ([#113](https://github.com/langwatch/kanban-code/issues/113)) ([bad627f](https://github.com/langwatch/kanban-code/commit/bad627f2241c6bb6d5cb741e0d8d3f44dc4b7c0e))
* **windows:** Codex adapter — discovery + AssistantId wiring ([#124](https://github.com/langwatch/kanban-code/issues/124) sub-PR 1/3) ([#132](https://github.com/langwatch/kanban-code/issues/132)) ([bdf3a5c](https://github.com/langwatch/kanban-code/commit/bdf3a5ca47a78d404528792b5aa5edcaba32f229))
* **windows:** confirm card delete + auto-select neighbor after delete/archive ([b43bc8f](https://github.com/langwatch/kanban-code/commit/b43bc8fd7e011cc7fbcb6c72f84a16d52ed43150))
* **windows:** copy-to-clipboard menu in card drawer header ([8a3d3fb](https://github.com/langwatch/kanban-code/commit/8a3d3fb571257ff8a84695e1a84a146219922bf4))
* **windows:** discovered-projects suggestions in Settings → Projects ([926a94d](https://github.com/langwatch/kanban-code/commit/926a94dccd0abe3d78edf6e3a4c09196d6df00fa))
* **windows:** DM panel in chat UI ([#109](https://github.com/langwatch/kanban-code/issues/109)) ([2d9c81c](https://github.com/langwatch/kanban-code/commit/2d9c81c4718d8461337e19dcac8b4b9b951bdd1f))
* **windows:** embedded WebView2 per browser tab + back/forward/reload ([#125](https://github.com/langwatch/kanban-code/issues/125) steps 3+4) ([#138](https://github.com/langwatch/kanban-code/issues/138)) ([fdab015](https://github.com/langwatch/kanban-code/commit/fdab0151330cd8c1b877a7cd58163f855b34314c))
* **windows:** emit drafts-changed watcher event ([#111](https://github.com/langwatch/kanban-code/issues/111)) ([c73078e](https://github.com/langwatch/kanban-code/commit/c73078e72d82897492711eea1346815b370609db))
* **windows:** fork_session + truncate_session — Fork in drawer menu, Checkpoint per turn ([b2827fc](https://github.com/langwatch/kanban-code/commit/b2827fcac072a9b49d9a8fe51c6dfb626b4942e6))
* **windows:** Gemini adapter — discovery + projects.json mapping ([#124](https://github.com/langwatch/kanban-code/issues/124) sub-PR 2/3) ([#133](https://github.com/langwatch/kanban-code/issues/133)) ([acab542](https://github.com/langwatch/kanban-code/commit/acab542e9a3f97241591aac6c528cf0b63d9c89d))
* **windows:** git_remote.rs + Tauri commands for canonical GitHub URLs ([da2e20a](https://github.com/langwatch/kanban-code/commit/da2e20a9ee5f378bc5d8c0f9adc58ffddd4b6011))
* **windows:** image upload in chat + CLI --image ([#112](https://github.com/langwatch/kanban-code/issues/112)) ([1a7d760](https://github.com/langwatch/kanban-code/commit/1a7d760af8faecc4cd9d25e839235befc31cd47d))
* **windows:** image-paste pipeline for prompts ([075f2f6](https://github.com/langwatch/kanban-code/commit/075f2f6aaa80f717ffe4e274baa2fd057dd8bff5))
* **windows:** image-paste pipeline for prompts and queued prompts ([8c4bc88](https://github.com/langwatch/kanban-code/commit/8c4bc88ce62ec08982afa3ce6b1d1d84bef6ffb2))
* **windows:** in-app merge_pr command + Merge pill in PR drawer tab ([406d411](https://github.com/langwatch/kanban-code/commit/406d41130308b9ee833ba5a475af0e64b6fa2925))
* **windows:** inject KANBAN_CARD_ID/HANDLE into card tmux launch ([#106](https://github.com/langwatch/kanban-code/issues/106)) ([2118df4](https://github.com/langwatch/kanban-code/commit/2118df440c9ce7cedcd03d0ae1c726a972ca14e7))
* **windows:** keyboard polish — Ctrl+, opens settings, Esc layer-pop ([f3a367f](https://github.com/langwatch/kanban-code/commit/f3a367f5d9c4a4e63b86cb5e46acc1b9889e9a72))
* **windows:** launch confirmation dialog + richer command builder ([8cde8e6](https://github.com/langwatch/kanban-code/commit/8cde8e63c35850dc41c5d6037295725173d4cae1))
* **windows:** log when settings.json appears to originate from macOS ([710c8da](https://github.com/langwatch/kanban-code/commit/710c8da7feb40f86dc2a8b7fe4d6dfdf4b806327))
* **windows:** make terminal shell configurable; default to native cmd.exe ([73fad21](https://github.com/langwatch/kanban-code/commit/73fad212d63662536e6ecb93b9454340352e760d))
* **windows:** move card to another project ([2e928b4](https://github.com/langwatch/kanban-code/commit/2e928b48997e53da9499f7c4c577e01c301c2e02))
* **windows:** multi-assistant abstraction (Claude + Gemini scaffolding) ([8e01c21](https://github.com/langwatch/kanban-code/commit/8e01c21454f86c0fd57afe743fdc51fb601a8e78))
* **windows:** multi-tab shells per card via tmux windows ([3bf5bf5](https://github.com/langwatch/kanban-code/commit/3bf5bf5ed5dfa79cf3704907f6093d98c9549469))
* **windows:** notification polish — last-message body + 62s dedup ([2ac5984](https://github.com/langwatch/kanban-code/commit/2ac59847294aea93214520d25083ff403064d418))
* **windows:** notifications for inbound chat messages ([#110](https://github.com/langwatch/kanban-code/issues/110)) ([c395f60](https://github.com/langwatch/kanban-code/commit/c395f604e8fa01a28ce2b61b2af55b58072212c3))
* **windows:** panic hook writes crash-*.log before abort ([d6713fd](https://github.com/langwatch/kanban-code/commit/d6713fd0684a6ce764ff951a2f219bbaafb7c1d5))
* **windows:** per-card runtime gate + in-terminal history + auto-resume ([#140](https://github.com/langwatch/kanban-code/issues/140)) ([0523d42](https://github.com/langwatch/kanban-code/commit/0523d429ffa000d84f6bfead13524aaba3150d98))
* **windows:** per-project settings — name, repoRoot, githubFilter, promptTemplate ([5718791](https://github.com/langwatch/kanban-code/commit/5718791f51e604a621e2efe37c81f92b489e40fc))
* **windows:** persist same-column reorder via reorder_cards command ([34e9b8a](https://github.com/langwatch/kanban-code/commit/34e9b8a90821cfc64b22f12a5b22a106babd22d3))
* **windows:** Phase 5 — Mutagen sync, remote status, bash wrapper deploy ([c0d59ba](https://github.com/langwatch/kanban-code/commit/c0d59ba3fec6eadba9c46fa2a0cc1c6e2fd6da3d)), closes [#96](https://github.com/langwatch/kanban-code/issues/96)
* **windows:** Phase 7 — channels + kanban CLI ([7ebda6b](https://github.com/langwatch/kanban-code/commit/7ebda6be6b0fe797f2197f48c74f6c82e2b9c6fe))
* **windows:** Phase 7 follow-ups (Parts 1–4) ([43daa0a](https://github.com/langwatch/kanban-code/commit/43daa0acba50e792f77600e047f8b4b66ea5bd90))
* **windows:** pinned cards + self-compact settings ([2d2a4c3](https://github.com/langwatch/kanban-code/commit/2d2a4c3dacaee46db5417c7aa81b7df858bd3c00))
* **windows:** pinned cards section + self-compact settings ([67d270a](https://github.com/langwatch/kanban-code/commit/67d270a41852020e7bedffd34f9ca94fc16f0d67))
* **windows:** port KSUID + add links.json .bkp corruption recovery ([6fd7739](https://github.com/langwatch/kanban-code/commit/6fd7739786d9923555022843b42a8b722db6a2c6))
* **windows:** Process Manager modal (Ctrl+Shift+M) ([a639cc2](https://github.com/langwatch/kanban-code/commit/a639cc2fcda8fc66ee41085a19c29e45e83413fe))
* **windows:** Process Manager modal (tmux / Claude / worktrees) ([a713e05](https://github.com/langwatch/kanban-code/commit/a713e05ae2017136f39296169c63c85711eb8baf))
* **windows:** Pushover delivery wired into notification path ([f831597](https://github.com/langwatch/kanban-code/commit/f831597ab1b05f36403c13ba308e93a884fcd37d))
* **windows:** queued-prompt auto-send driven by hook Stop events ([ca66f91](https://github.com/langwatch/kanban-code/commit/ca66f9122e32bc0669aede9685ef040f6b399b12))
* **windows:** rich PR enrichment — body, CI checks, review decision, approvals ([37deb36](https://github.com/langwatch/kanban-code/commit/37deb362a4846dbd1e2f9530dc74918170ed2856))
* **windows:** self-compact generation loop + Claude Code statusline ([#131](https://github.com/langwatch/kanban-code/issues/131)) ([6f6956f](https://github.com/langwatch/kanban-code/commit/6f6956f2576a3c41893e16c81ee447176ae434b6))
* **windows:** Session History parity — transcript font + auto-load ([770c5e4](https://github.com/langwatch/kanban-code/commit/770c5e4520cff2f56003305c41d74f345eee1f74))
* **windows:** Session History parity — transcript font size + auto-load ([cfea354](https://github.com/langwatch/kanban-code/commit/cfea354b0d5375407043d8b268761347d2efcde9))
* **windows:** standalone parity gaps — lastOpenedAt, channel reorder, bulk kill, Ctrl+click checkpoint ([#129](https://github.com/langwatch/kanban-code/issues/129)) ([7826c89](https://github.com/langwatch/kanban-code/commit/7826c893ead0a5a8d757ff97dc1f7708adca0153))
* **windows:** tmux-in-WSL adapter for terminal persistence (Phase 3) ([965a797](https://github.com/langwatch/kanban-code/commit/965a797ef4728c6b58944bec487cab6494b141bf))
* **windows:** unresolved-thread count + worst-CI dot on card ([06dc71b](https://github.com/langwatch/kanban-code/commit/06dc71b495fde60126f402a0c806a94148674042))
* **windows:** wire git worktree discovery + add Remove worktree action ([e00f29d](https://github.com/langwatch/kanban-code/commit/e00f29d37c03cd93270815529673aabe1e6f8d18))
* **windows:** wrap embedded terminal in tmux for reattach across drawer close ([f7e4edb](https://github.com/langwatch/kanban-code/commit/f7e4edb738341547750f024668e4a10fc82af2d1))
* **windows:** WSL terminal-shell hint in onboarding ClaudeCodeStep ([8659440](https://github.com/langwatch/kanban-code/commit/8659440f6dd49e5ffe43f720e48e014e5ab7b5c6))
* **windows:** WSL-side hook.sh install + JSONL event tail ([7fff195](https://github.com/langwatch/kanban-code/commit/7fff19502e271d082fd64e98f85c01293c928095))


### Bug Fixes

* **cli:** delete a channel's history log on channel delete ([d1fb6bf](https://github.com/langwatch/kanban-code/commit/d1fb6bf7fc6967ef2c05ee038909e107b84fa35b))
* **cli:** forceFresh mints a unique session id, not uuidv5(slug) ([2775ef7](https://github.com/langwatch/kanban-code/commit/2775ef7b1f87a465c12807036407c370ddb750c1))
* **cli:** fresh ephemeral room agents + clean channel teardown ([9ae55af](https://github.com/langwatch/kanban-code/commit/9ae55af24892d8e4fed03944d071f8f87eab7c12))
* **cli:** prioritize channel help over low-level send ([3410a9f](https://github.com/langwatch/kanban-code/commit/3410a9fbe726ecec18ff699d8db5a94ef85f278a))
* **self-compact:** prioritize compact queue prompts ([263caaf](https://github.com/langwatch/kanban-code/commit/263caaf1df0c1dad0ca4ef769700194df41d94a1))
* **slack:** clear pill + delete 👀 when the user runs /stop ([6b9fc4c](https://github.com/langwatch/kanban-code/commit/6b9fc4ca2e06216c91625a5fb79cbc91590e6051))
* **slack:** drop stale pill on bridge restore when the agent's turn already ended ([f9e0fc1](https://github.com/langwatch/kanban-code/commit/f9e0fc1c03dcbd33cb92fab6211e65b2676620a4))
* **slack:** skip the 👀 ack on relay when the agent is already mid-turn ([a988068](https://github.com/langwatch/kanban-code/commit/a98806835dbf82b8fe25c2a1635ad40864d5d9dc))
* **tmux:** route every paste through a uniquely-named buffer ([ed3f458](https://github.com/langwatch/kanban-code/commit/ed3f458836ff6619ba08567a4cd3b0f713b93e0b))
* **windows:** harden crash handler against recursive panic + cross-PID race ([1c8ea43](https://github.com/langwatch/kanban-code/commit/1c8ea436602dd1158154a3ba048f793fc4c47ba0))
* **windows:** image-paste review fixes — renumber on remove + persist edits ([24a403b](https://github.com/langwatch/kanban-code/commit/24a403b32aef88edffddf5f55c10e1484eab6a8a))
* **windows:** keyboard shortcuts also match on physical key code ([0145fc5](https://github.com/langwatch/kanban-code/commit/0145fc5e182be47a6ed3d2d4689778ddf7d5a4e4))
* **windows:** make Transcript font size slider actually take effect ([809b3a7](https://github.com/langwatch/kanban-code/commit/809b3a7347fefb96bb9cd78d9f5b94a036217682))
* **windows:** process-manager review fixes — tighten filter + flag boundary ([545625d](https://github.com/langwatch/kanban-code/commit/545625da09b2fb19e7e30efcad3b28b4e008963f))
* **windows:** thread theme tokens through dark-hardcoded views ([b2081a8](https://github.com/langwatch/kanban-code/commit/b2081a8088a8703b2b912c7ac11295f74fb159e1))


### Performance

* **windows:** chunked reverse-tail in read_jsonl ([#114](https://github.com/langwatch/kanban-code/issues/114)) ([c440955](https://github.com/langwatch/kanban-code/commit/c440955b4ae10fc23cc496b8809487293ff8c8b9))


### Refactoring

* **windows:** collapse tail_messages into read_messages ([#107](https://github.com/langwatch/kanban-code/issues/107)) ([35a4771](https://github.com/langwatch/kanban-code/commit/35a4771e3bcae166384c3dd6825b034696c4702b))

## [0.1.29](https://github.com/langwatch/kanban-code/compare/v0.1.28...v0.1.29) (2026-06-07)


### Features

* **board:** add pinned cards section ([3e72a89](https://github.com/langwatch/kanban-code/commit/3e72a89034df3c1bc4958db9006408b343af395e))
* **board:** reorder channels and pinned cards ([160c492](https://github.com/langwatch/kanban-code/commit/160c4923936435fa871f49ac4d1328a676e6e9dc))
* **bridge:** mirror Codex agent movement to Slack via rollout transcript ([c330f35](https://github.com/langwatch/kanban-code/commit/c330f3587dff393d2f4204e99155f25d6d611c09))
* **card:** copy conversation as markdown ([383b8f8](https://github.com/langwatch/kanban-code/commit/383b8f8203484c7e891001e293fab0311dc4780c))
* **channels:** copy conversation as markdown ([5c31168](https://github.com/langwatch/kanban-code/commit/5c3116881f403ba61b57428335b0df8c931aaafe))
* **cli:** headless agent runtime (launch/resume, reconcile, daemon, hooks, slack) ([afc01cc](https://github.com/langwatch/kanban-code/commit/afc01cc9cf7a5019e378708b5d5752161df22ffa))
* **cli:** headless agent runtime (launch/resume, reconcile, daemon, hooks, slack) ([86012bf](https://github.com/langwatch/kanban-code/commit/86012bfc58fdae392f6c681115db5c9aa63e45c9))
* **headless:** add a Codex runtime alongside Claude ([06be666](https://github.com/langwatch/kanban-code/commit/06be666cc392b25035297f459355d894f6a8282f))
* **headless:** add a Codex runtime alongside Claude ([2983a12](https://github.com/langwatch/kanban-code/commit/2983a1250c3dc6a8b5408c0799cae01599885163))
* **slack:** /stop slash command to interrupt the agent in its channel ([30f7fda](https://github.com/langwatch/kanban-code/commit/30f7fda3829282700928cf4289afab818a579f83))
* **slack:** add 'kanban slack post' to post to a channel as the bot ([631ed55](https://github.com/langwatch/kanban-code/commit/631ed5546cc729c118c11b5912313feca4beecb8))
* **slack:** age out attachments after 7 days so the inbox does not grow ([5da540e](https://github.com/langwatch/kanban-code/commit/5da540e0a14e834a3c6a58464ce67e949d20a9b1))
* **slack:** announce self-compact in the channel ([31317a7](https://github.com/langwatch/kanban-code/commit/31317a746e8fc75277a1145570456a32d6a07529))
* **slack:** broaden bot scopes to full read + write in any invited channel ([b8b1002](https://github.com/langwatch/kanban-code/commit/b8b100228c4722d48326ac48d30757d3bd4a5340))
* **slack:** buffer tool calls and flush them on the NEXT text post ([227ae06](https://github.com/langwatch/kanban-code/commit/227ae06d4fdeac994c4ac5b72e2a20a26873c520))
* **slack:** follow codex rollout rotation so mirroring survives restarts/compaction ([552f0b5](https://github.com/langwatch/kanban-code/commit/552f0b5e359f051bb9762bbd539c8a59ce7ad333))
* **slack:** live "working…" pill via assistant.threads.setStatus ([04439a8](https://github.com/langwatch/kanban-code/commit/04439a812f1123c51044fb6efc8942f9e22e937d))
* **slack:** mark automated sends with [SYSTEM MESSAGE] ([07d46e3](https://github.com/langwatch/kanban-code/commit/07d46e3ac8e475448f3026e754525ba1d8af3ddd))
* **slack:** mirror Claude Code's numbered picker as Slack buttons ([c40e6fb](https://github.com/langwatch/kanban-code/commit/c40e6fb2cf16bb7815cebd496238be0cad2f5623))
* **slack:** mirror codex out-of-credits to the channel ([e3955c5](https://github.com/langwatch/kanban-code/commit/e3955c5c876b27548b6bfbe8f7c5b31a161f3d63))
* **slack:** mirror codex received prompts as '&gt;&gt;&gt; Received user message' ([c4429d9](https://github.com/langwatch/kanban-code/commit/c4429d954bf73db6dc5ad7e0de4155e1859f7acc))
* **slack:** mirror every injected prompt as "&gt;&gt;&gt; Received user message" ([cc6fa1e](https://github.com/langwatch/kanban-code/commit/cc6fa1ed3fa92c9d8f88c14dc1cebc35da295ec2))
* **slack:** relay file attachments into the agent prompt ([25d5bb1](https://github.com/langwatch/kanban-code/commit/25d5bb1123b81e2008aaa3b0788509b5227e4b8d))
* **slack:** relay file attachments to the agent's tmux prompt ([77ce266](https://github.com/langwatch/kanban-code/commit/77ce266a880e5fea1f959d78f712b302828a1e2c))
* **slack:** render command tool calls in fenced code blocks ([65d1a59](https://github.com/langwatch/kanban-code/commit/65d1a5999e541d9b6a48c3050e348f2dfe4bf42b))
* **slack:** route text to channel root, fold tool calls into in-thread batches ([e6571a5](https://github.com/langwatch/kanban-code/commit/e6571a507b9e7abd023b221b71b3472ba2c5d867))
* **slack:** thread agent activity under the received prompt ([8381dc6](https://github.com/langwatch/kanban-code/commit/8381dc64d448acf28db15dcfb7f19639e1d37a5d))
* **slack:** translate GFM markdown to Slack mrkdwn before posting ([e0c817a](https://github.com/langwatch/kanban-code/commit/e0c817a5fc0e2351bb3e9b92837a5da416f4d9d7))


### Bug Fixes

* **app:** make quit confirmation app-modal ([0e878f5](https://github.com/langwatch/kanban-code/commit/0e878f5bffeb8674de57cb3b31e7e5f86af4aa9a))
* **app:** make quit confirmation delegate-owned ([2d8f0b8](https://github.com/langwatch/kanban-code/commit/2d8f0b81b6407a08571b0c62cb309be8ec03626f))
* **app:** present quit confirmation reliably ([56b462a](https://github.com/langwatch/kanban-code/commit/56b462a03003dbebabc67095ac6874bed8de772a))
* **app:** restore managed-session quit dialog ([c376a68](https://github.com/langwatch/kanban-code/commit/c376a6825b90a3d83fc49922df7caeab3c42c63f))
* **board:** avoid lazy layout hang when pinning cards ([02a2b1d](https://github.com/langwatch/kanban-code/commit/02a2b1da22b6110d1b95e05ca7052987974649b4))
* **bridge:** match codex rollout cwd via regex (session_meta line is huge) ([a9176ec](https://github.com/langwatch/kanban-code/commit/a9176ecd9cb9ebc6f84b76f3bd4617ce6534b11f))
* **build:** bundle the whole cli/dist tree, not just top-level files ([5fce3e5](https://github.com/langwatch/kanban-code/commit/5fce3e5b4156a7d6cb56168f4de32250db26453a))
* **channels:** avoid heavy markdown render hangs ([a293d9c](https://github.com/langwatch/kanban-code/commit/a293d9c0351fca1a35f6baa2876979b7630b3fdb))
* **channels:** avoid reloading cached message tails ([5ea50e6](https://github.com/langwatch/kanban-code/commit/5ea50e6047b7d8667c5b4d071669e0a00072e3a0))
* **channels:** cap chat rendering hot path ([4600dd4](https://github.com/langwatch/kanban-code/commit/4600dd488813ac57f2965820cf34168a86613844))
* **channels:** skip no-op state reloads ([4e04853](https://github.com/langwatch/kanban-code/commit/4e04853cc48e87e1e1037cd8c41e95bedc7ea20b))
* **chat:** avoid history pagination plateau ([b565af8](https://github.com/langwatch/kanban-code/commit/b565af8cd698a91ba76e1acdb0f27cf31f1f720d))
* **codex:** resume the prior session on restart instead of starting fresh ([0df50c8](https://github.com/langwatch/kanban-code/commit/0df50c8509495dc7e8385946b58ebd00ab089bde))
* **daemon:** send self-compact nudge straight away, not queued for Stop ([ec0767a](https://github.com/langwatch/kanban-code/commit/ec0767a07230cbdbca522aa472556e027c483bc1))
* **hooks:** wrap codex hooks.json events under top-level "hooks" key ([9665210](https://github.com/langwatch/kanban-code/commit/966521027452010c10141f5d8d74e3a0bb2fa7ab))
* make channel live share startup reliable ([0871638](https://github.com/langwatch/kanban-code/commit/08716387e7c001d0819de2eb347907f5461ec644))
* **notifications:** bound transcript reads ([93d1737](https://github.com/langwatch/kanban-code/commit/93d17371a463bca12f357dbbdc209f3525ffcb70))
* remeasure prompt editor after complex pastes ([440afa7](https://github.com/langwatch/kanban-code/commit/440afa74b119bd59010a8d4516e4673bbcad812c))
* **search:** exact PR and URL deep search ([911c2fb](https://github.com/langwatch/kanban-code/commit/911c2fbce553d9a94160b3940c0ea4b6330fe1c6))
* **search:** highlight quoted exact matches ([5252817](https://github.com/langwatch/kanban-code/commit/5252817f036438ca39273d917c0a83d00308bcd0))
* **search:** make PR deep search exact and fast ([6e3d487](https://github.com/langwatch/kanban-code/commit/6e3d4875f82dba612e53f128701d019dec667733))
* **self-compact:** give Claude Code 2s to settle before sending Escape ([433130e](https://github.com/langwatch/kanban-code/commit/433130e5cfd505abcf8100dcc8e915ed0e678636))
* **slack:** also detect the footer-less 'Review your answers' submit picker ([961386d](https://github.com/langwatch/kanban-code/commit/961386d63b5f4a4c31235cca1bfb2a65361426c0))
* **slack:** clear the previous "is working…" pill explicitly on each new text ([8ca0dde](https://github.com/langwatch/kanban-code/commit/8ca0dde1be402cdc929a8df22b982a3d6787cf94))
* **slack:** drop "is working…" pill on codex out-of-credits ([f904adb](https://github.com/langwatch/kanban-code/commit/f904adbc29c2fb287f0217c30ee7c0baa3be27d8))
* **slack:** drop the eyes-emoji ack post; light the pill on the prior anchor ([4bdc027](https://github.com/langwatch/kanban-code/commit/4bdc0270125fec5fce9d138310614958ac16f039))
* **slack:** drop the working pill when a codex turn ends (task_complete) ([a8d68d6](https://github.com/langwatch/kanban-code/commit/a8d68d64b550347c9daee9a876e0bacfb30e5562))
* **slack:** drop the working pill when Claude finishes its turn (end_turn) ([0d670d9](https://github.com/langwatch/kanban-code/commit/0d670d95d923e21ee598fc686c11322d02f2d3f1))
* **slack:** drop working pill on codex out-of-credits warning ([437d1df](https://github.com/langwatch/kanban-code/commit/437d1dfd3491db05b9ab0b0374169cc733b9bf19))
* **slack:** light the working pill the moment we deliver a user prompt ([15fb4a9](https://github.com/langwatch/kanban-code/commit/15fb4a991a96e00678d1b2f029842f3f9a92a80e))
* **slack:** light working pill immediately when a Slack human relays a prompt ([5dd137a](https://github.com/langwatch/kanban-code/commit/5dd137aa352c6e5bc2dd8b462cfc83ba77accd60))
* **slack:** mirror prompts only on confirmed receipt, suppress bridge echoes ([8792f8a](https://github.com/langwatch/kanban-code/commit/8792f8a8b180ff68ff56b44e816606bfdb2e4d66))
* **slack:** persist the working pill across bridge restarts ([2667543](https://github.com/langwatch/kanban-code/commit/266754323bef9c92f9babf6b19cf5fa37f6a911b))
* **slack:** persist working pill across bridge restarts ([d8591b1](https://github.com/langwatch/kanban-code/commit/d8591b18ac1521cb8930f91153899c94a090c679))
* **slack:** post pickers to channel root, not into the current thread ([20a5a84](https://github.com/langwatch/kanban-code/commit/20a5a84d099c4f2b0cfc0a61c8e2f0324213e8dd))
* **slack:** render agent markdown + drop stale pill on Claude end_turn ([2aaa594](https://github.com/langwatch/kanban-code/commit/2aaa5945aea89d287a6ba0665a0d5072e5c46fcf))
* **slack:** thread Claude agent activity too, via a shared thread-root ([759a298](https://github.com/langwatch/kanban-code/commit/759a2980d4a229d58e1d22fa6f41943821d89611))
* stabilize prompt editor height measurement ([cfacf24](https://github.com/langwatch/kanban-code/commit/cfacf240734cffbfa5346d4690590c3290e1d48f))
* **store:** isolate chat actions from card rebuilds ([0a5dd5e](https://github.com/langwatch/kanban-code/commit/0a5dd5eedf38a90eafaddfb156b626a9a74dfada))
* **transcript:** preserve slash command prompt text ([db42014](https://github.com/langwatch/kanban-code/commit/db420141a075578565481628c76f659976d6b430))
* **ui:** keep watcher notifications on main thread ([78a92e2](https://github.com/langwatch/kanban-code/commit/78a92e29de23f83a5e09779f7c54670d7d918af0))
* wait for share tunnel warmup before publishing URL ([6bf744d](https://github.com/langwatch/kanban-code/commit/6bf744de3c1f56b9fc75a2a5724a1170a52e64f3))


### Performance

* **terminal:** reuse resolved render attributes ([49a6176](https://github.com/langwatch/kanban-code/commit/49a6176286998f3fe5f3fb8d43a7a475ac9764a7))


### Refactoring

* **card-menu:** require explicit action routing ([ec40ef9](https://github.com/langwatch/kanban-code/commit/ec40ef97345f3fc48af4c799e2b9ee852c9c88d3))
* **slack:** drop per-tool status label, show plain "working…" pill ([ce5aa83](https://github.com/langwatch/kanban-code/commit/ce5aa835eabb4d7bb4624083b62693e58fba67d9))


### Documentation

* **cli:** operator guide for headless agents ([4964b0e](https://github.com/langwatch/kanban-code/commit/4964b0e4529317cd4dacf0cc076145b28f09c8d1))
* **spec:** codex mirrors via rollout transcript, not hooks ([2cb8583](https://github.com/langwatch/kanban-code/commit/2cb8583337359c2650deacec559dfca51e65b0fa))

## [0.1.28](https://github.com/langwatch/kanban-code/compare/v0.1.27...v0.1.28) (2026-05-23)


### Features

* **app:** improve prompts and self compact settings ([50915f2](https://github.com/langwatch/kanban-code/commit/50915f2cf218e2b87f53428867cfba00f16b34a2))
* **channels:** add from filters to search ([7c8a4d1](https://github.com/langwatch/kanban-code/commit/7c8a4d1c1f8b7305315fdf6649aa199ccbb2bfe3))
* **cli:** add self-compact command ([fdda9c2](https://github.com/langwatch/kanban-code/commit/fdda9c267604649daa97d43f03c1d636b885dd3c))
* **prompts:** preserve inline image placement ([e577db4](https://github.com/langwatch/kanban-code/commit/e577db45d8a169a2372d1663543fdd147ec91bfc))
* **settings:** link to full disk access permission ([971ab1f](https://github.com/langwatch/kanban-code/commit/971ab1fd1f2ef68a8519ff9b13f5e8072fa073ad))
* **shortcuts:** resume ended sessions with command return ([c76f94e](https://github.com/langwatch/kanban-code/commit/c76f94e62231e8553dad7cdd741e7027bed7ed69))
* **ui:** add channel activity and navigation cues ([bd9ab1e](https://github.com/langwatch/kanban-code/commit/bd9ab1eb8e676c3a4733d84e08a51cc7d37c0930))


### Bug Fixes

* **app:** avoid stale self compact prompts ([d66a6ce](https://github.com/langwatch/kanban-code/commit/d66a6ce31e3efb17db8d99f1b8f34b4368766f93))
* **app:** include message participants in channel activity ([c04b20f](https://github.com/langwatch/kanban-code/commit/c04b20f18d5560e4d2f22189779ad5166685cf81))
* **app:** reduce UI hangs and stale undo crashes ([796c5e1](https://github.com/langwatch/kanban-code/commit/796c5e1473a8856c615677fff673bda134a04283))
* **app:** throttle active card branch discovery ([e37aaf4](https://github.com/langwatch/kanban-code/commit/e37aaf49b300725cbcda6aeb3a6d46f0732bc313))
* **channels:** improve search and hang diagnostics ([4235f35](https://github.com/langwatch/kanban-code/commit/4235f35b0a9a04b2fd3d9d83d697e935dad7201f))
* **channels:** repair tmux ownership and self-compact follow-up ([7370ab9](https://github.com/langwatch/kanban-code/commit/7370ab91d2a9d03109ac8d928a03fb9669e1b65d))
* **chat:** page Codex history and restore working state ([25dbc86](https://github.com/langwatch/kanban-code/commit/25dbc864d64d4559bffc5ef6de0e8136e3a2100e))
* **cli:** submit self compact command reliably ([f8c8528](https://github.com/langwatch/kanban-code/commit/f8c852875e96b4b4991d581d8758b277e7865366))
* **cli:** use fixed self compact follow-up delay ([4057c0c](https://github.com/langwatch/kanban-code/commit/4057c0c34ca5db1d40b98c71caddecf2942e74fa))
* **launch:** keep prompt text with image attachments ([36d305a](https://github.com/langwatch/kanban-code/commit/36d305ad8d00dee8c24e902c0b4ecdb34c18647a))
* limit activity refresh to discovered sessions ([2eb52bb](https://github.com/langwatch/kanban-code/commit/2eb52bb9a1bfeea45e9c5a5696f7f518fca6ea1f))
* stabilize chat rendering and add UI diagnostics ([825640b](https://github.com/langwatch/kanban-code/commit/825640b257f9a3cbdaf440945d41f151b8fce971))
* **store:** avoid observable state exclusivity crash ([4a7c2d7](https://github.com/langwatch/kanban-code/commit/4a7c2d77f08ff0bee3054feb4a80182aff990e53))
* **ui:** reduce channel render load and stabilize prompt height ([44213ca](https://github.com/langwatch/kanban-code/commit/44213ca012408a4987ea5ae7eff227b721249612))
* **ui:** render all card toolbar PR pills ([6afd05c](https://github.com/langwatch/kanban-code/commit/6afd05cb8b81df757f3a3430a905596efa3b0399))
* **ui:** render card drawer PRs as separate toolbar buttons ([4336516](https://github.com/langwatch/kanban-code/commit/4336516e2cfea687129ee536e08d4c3e044d92bc))
* **ui:** show more PR buttons in card toolbar ([fa6e2b5](https://github.com/langwatch/kanban-code/commit/fa6e2b581fe66b39fa2dfefd36c2cb82da77db62))
* **ui:** show sorted PR badges in card drawer ([9a47f99](https://github.com/langwatch/kanban-code/commit/9a47f9974df2e63585e8292a0358af3609d31a63))

## [0.1.27](https://github.com/langwatch/kanban-code/compare/v0.1.26...v0.1.27) (2026-04-29)


### Features

* **channels:** improve navigation search and memory use ([40007df](https://github.com/langwatch/kanban-code/commit/40007df07208cbe8a258886c5ac4ecc0027156a0))


### Bug Fixes

* **reconciler:** drop stale orphan worktrees ([6ad2572](https://github.com/langwatch/kanban-code/commit/6ad25727579f0dcc611aa15e6661085fc2b47986))
* **search:** stabilize quick palette selection ([3e83afb](https://github.com/langwatch/kanban-code/commit/3e83afb1bd110edca49f48191323e8e384e45623))

## [0.1.26](https://github.com/langwatch/kanban-code/compare/v0.1.25...v0.1.26) (2026-04-25)


### Features

* [@mention](https://github.com/mention) autocomplete in channel/DM composer ([f87764f](https://github.com/langwatch/kanban-code/commit/f87764fa8268d0e9a9aeecfc74bc13bfa9b66964))
* add Codex CLI assistant support ([338788f](https://github.com/langwatch/kanban-code/commit/338788f194e1910924626826f1df4403b67b72eb))
* **api-service:** third-party launcher support (Ollama, model flags, base URL) ([12fd29a](https://github.com/langwatch/kanban-code/commit/12fd29aff58fc47fd596f026240646b9588073e2))
* **api-service:** third-party launcher support via APIService entity ([0b094e3](https://github.com/langwatch/kanban-code/commit/0b094e353844f6341dcbca89131d60948594e1ae))
* broadcast message images via inline markdown paths ([a61012e](https://github.com/langwatch/kanban-code/commit/a61012e68ee1e2b4f8d57c6daba4e92b6e82af26))
* browser tab shortcuts and new-tab link handling ([3e41a9d](https://github.com/langwatch/kanban-code/commit/3e41a9d428f4ee98bb8d0dedb982af0b57354f00))
* **channels:** kick members, markdown + truncation, logger & codex fixes ([f654acd](https://github.com/langwatch/kanban-code/commit/f654acdeb3b896a142f1d78e5d397d1ec63d7b66))
* **channels:** tint own messages in channel and DM views ([1db6ccd](https://github.com/langwatch/kanban-code/commit/1db6ccdc4b9959aebf94c1b3134b56dbca99d626))
* **chat:** arrow-key nav + escape for @-mention picker ([370866f](https://github.com/langwatch/kanban-code/commit/370866f7d27390892d49674db12885d67dcafaa1))
* **chat:** Enter inserts top mention match when picker is open ([938cfb6](https://github.com/langwatch/kanban-code/commit/938cfb64a7e1e43e7c86fc3a16529bb4d9022038))
* **chat:** flag external messages with a warning prefix in tmux fanout ([27ce61b](https://github.com/langwatch/kanban-code/commit/27ce61b7f9ae91b1e29a7931d448393e57525e00))
* **chat:** text selection, cmd+click URLs, smart scroll, and new-messages pill ([f25de70](https://github.com/langwatch/kanban-code/commit/f25de708cd4887d20d0ae4920667243aa1f5ab86))
* Cmd+Shift+T reopens last closed tab, address bar focused on new tab ([4a1416b](https://github.com/langwatch/kanban-code/commit/4a1416b143e06586298ec3ce9c9407e52904ad75))
* first-class chat channels for multi-agent coordination ([826c61a](https://github.com/langwatch/kanban-code/commit/826c61a4b5fe4b035f2fa8d507f0f52786c596a1))
* kanban channel/dm open deep-links into the app ([f25b577](https://github.com/langwatch/kanban-code/commit/f25b577752cd730d860feff48f3dd03862b37a98))
* **share:** headless share-server + cloudflared tunnel + kanban channel share ([4197980](https://github.com/langwatch/kanban-code/commit/4197980d79b927cd9debf28c3f3b9a4cee88d858))
* **share:** OpenAPI spec at /.well-known + "API for Agents" button ([637e8bf](https://github.com/langwatch/kanban-code/commit/637e8bf1a1bd7cb4656afa600c6bac259ce68aa8))
* **share:** robustness, images, theme toggle, and polish ([b702979](https://github.com/langwatch/kanban-code/commit/b7029796ab6b76ab9e9dd7ff2d56d7af94d9ba7d))
* **share:** swap SSE for long-polling + drop 50 MB of dev deps ([2af885e](https://github.com/langwatch/kanban-code/commit/2af885eb840bb5f006714c405f3ec5d51deba556))
* **share:** Swift UI for public channel shares ([66539d0](https://github.com/langwatch/kanban-code/commit/66539d0beefb7ed10786b542af1492cd35e3f608))
* **share:** web client (Vite + React + Tailwind + shadcn) ([59e048f](https://github.com/langwatch/kanban-code/commit/59e048f062b2adb112f551ad1ea976b2cbe304f8))
* **storage:** rolling 7-day backup snapshots of links.json ([f24c0cd](https://github.com/langwatch/kanban-code/commit/f24c0cd86496aed0867e488c3a2f24b9addd1c89))
* TypeScript CLI for card inspection and agent orchestration ([f0eb6df](https://github.com/langwatch/kanban-code/commit/f0eb6df18ff255d32c9fc590f5ec559629b3b304))


### Bug Fixes

* **activity:** detect ralph-loop / stop-hook continuation via transcript mtime ([87bc0d9](https://github.com/langwatch/kanban-code/commit/87bc0d93c6bfc1dc0493eaac9d0d6ed119fbb721))
* **activity:** route detectors to their own sessions ([08fcde5](https://github.com/langwatch/kanban-code/commit/08fcde5a42d01d47b9917188e0c2e071dc46c461))
* apply excluded paths filter to CLI card listing ([b7fe51e](https://github.com/langwatch/kanban-code/commit/b7fe51e5cf1ca1389c0e805e9e4dc8eb99dbbc24))
* apply same activeTimeout window to Notification handler ([42be99a](https://github.com/langwatch/kanban-code/commit/42be99ab8bfbe4bbdf2fad180054d831f135eac1))
* **build:** use ad-hoc codesign for local dev builds ([ab7c03b](https://github.com/langwatch/kanban-code/commit/ab7c03b6bdd305ddea0a34bec955ce968796e220))
* **build:** use ad-hoc codesign for local dev builds ([3135148](https://github.com/langwatch/kanban-code/commit/3135148c71a26b135091d47aed019cbf56bc9e7d))
* **card-detail:** discard stale transcript loads after card switch ([285635a](https://github.com/langwatch/kanban-code/commit/285635a000fc8bf49a31724f631c3ed090056ba9))
* **card:** focus terminal on card switch when focusTerminal is already true ([c879b0f](https://github.com/langwatch/kanban-code/commit/c879b0fe4c5686d856c8ef9292dd02c0d23e50c8))
* chat scroll rewrite, send reliability, terminal selection, tmux discovery ([fb3d256](https://github.com/langwatch/kanban-code/commit/fb3d256eb6b649d3fb373111240838d10d8038ff))
* **chat:** Enter in @-mention picker inserts selected handle ([9bd673a](https://github.com/langwatch/kanban-code/commit/9bd673a9f0f41617506eb9249e0621c990ab4b30))
* **chat:** float mention popover above composer (no layout shift) ([1ff85f1](https://github.com/langwatch/kanban-code/commit/1ff85f1eab50b9cf00638779702403c60a707e5c))
* **chat:** mention popover sits above composer + hover highlight ([bf9de4f](https://github.com/langwatch/kanban-code/commit/bf9de4f3328bb45a7f66cab3a3a305da3d3d4081))
* **chat:** re-focus chat composer / card terminal on drawer switch ([f0c5347](https://github.com/langwatch/kanban-code/commit/f0c5347b2cf69ac03a81610cdf9e35d6973ea613))
* disable noUnusedLocals and noUnusedParameters in tsconfig ([919aee8](https://github.com/langwatch/kanban-code/commit/919aee80f36a3381cd97f620da6c27492c8d8a9f))
* disable noUnusedLocals and noUnusedParameters in tsconfig ([be2eb8b](https://github.com/langwatch/kanban-code/commit/be2eb8bb1caf0056d1b7db1c9fb3fee0731f99d6))
* native WebKit inspector via entitlements and autoresizing ([3a93ec9](https://github.com/langwatch/kanban-code/commit/3a93ec9b0d78ca2d4a8cf0c0efdbfff8c768bafa))
* prevent reconcile from reverting configuredProjects ([639ab6a](https://github.com/langwatch/kanban-code/commit/639ab6abc23547ee25d21c319647928acbb46cc4))
* **reconciler:** catch branch checkout inside existing worktrees ([1985c14](https://github.com/langwatch/kanban-code/commit/1985c14e51dbb38caa9dd4300ae09156b35d2913))
* **settings:** one bad field can no longer wipe the whole config ([4d0add8](https://github.com/langwatch/kanban-code/commit/4d0add806718c7837f18028c23e93e466a35e1cf))
* stable notification identifier per channel/dm ([3c7321e](https://github.com/langwatch/kanban-code/commit/3c7321e25476233dfacfd17eee4f2ecf6e78e4f9))
* Stop grace period instead of 5-min activeTimeout window ([7591122](https://github.com/langwatch/kanban-code/commit/75911221361765b31217b8c93017f5d4a331e7c9))
* stop Stop-event flicker without promoting dormant sessions ([8185d3d](https://github.com/langwatch/kanban-code/commit/8185d3dae998d7ef94a0c5e9091bd294e247b94e))
* use stable code signing and disable smart text substitutions ([3b6db1b](https://github.com/langwatch/kanban-code/commit/3b6db1ba7d9279b2f4d8dd0d0a4a99c82f51e926))
* use which instead of where for command detection on Linux ([a481ebe](https://github.com/langwatch/kanban-code/commit/a481ebe78353659b257961746d4ca11a89424b78))
* use which instead of where for command detection on Linux ([c8726b5](https://github.com/langwatch/kanban-code/commit/c8726b54440e27c6bd29b3350c205cf376a64edd))


### Refactoring

* include markdown image refs in Swift fanout (parity with CLI) ([712b692](https://github.com/langwatch/kanban-code/commit/712b69261fa1c7d48531a4c4d898796d485f242d))

## [0.1.25](https://github.com/langwatch/kanban-code/compare/v0.1.24...v0.1.25) (2026-04-07)


### Features

* add `kanban` CLI and centralize shortcut display strings ([8a7420b](https://github.com/langwatch/kanban-code/commit/8a7420bbaa90601fbdf61c6c25381b0a17fe702a))
* clickable [#123](https://github.com/langwatch/kanban-code/issues/123) PR refs in chat mode, fix blank rendering ([a78b8ba](https://github.com/langwatch/kanban-code/commit/a78b8ba7d0e948f6b359b7ddc42252ceb3654ca9))
* cmd+click GitHub issue/PR refs ([#123](https://github.com/langwatch/kanban-code/issues/123)) in terminal ([8d620ec](https://github.com/langwatch/kanban-code/commit/8d620eca8d025b00ae81add4f0d1955fa26d1c26))


### Bug Fixes

* absorb new sessions by project+tmux, copy all grouped messages, add checkpoint ([6aeb023](https://github.com/langwatch/kanban-code/commit/6aeb023d7fdb76936bd99da01dbd43469319d33f))
* Add Link always visible, Show more clickable, notification-based Add Link ([d099da6](https://github.com/langwatch/kanban-code/commit/d099da687b0a23f25a9918f45627b5a73abd19c0))
* chat mode scroll, rendering, and UX improvements ([7260393](https://github.com/langwatch/kanban-code/commit/72603930ea1b533c4ebd56cc93758906f56e49bd))
* drop custom equatable on ChatMessageView ([75ac58b](https://github.com/langwatch/kanban-code/commit/75ac58b8bb1a960b6f4c04d9cc9461744a628bf3))
* resolve type-checker timeout in CardDetailView onChange ([61b4e77](https://github.com/langwatch/kanban-code/commit/61b4e77b0fb40615951dc49749978770126926e5))
* resolve type-checker timeout in CardDetailView onChange ([38a9bf7](https://github.com/langwatch/kanban-code/commit/38a9bf7db5b9f2d9924a384a585d4d50a26c0c44))
* rotate log file on startup when over 10MB ([d8d2aeb](https://github.com/langwatch/kanban-code/commit/d8d2aeb68d5fa68e2d6dfa50ce1025652b46d017))
* update worktreeLink when Claude switches worktrees (EnterWorktree) ([e3f921c](https://github.com/langwatch/kanban-code/commit/e3f921c5065e0f09ba38424c98ac2ed7635c39dd))


### Performance

* virtualize card list in expanded sections ([df8e920](https://github.com/langwatch/kanban-code/commit/df8e9207b48137c1caa0b39f6a92d06160a3d4c0))

## [0.1.24](https://github.com/langwatch/kanban-code/compare/v0.1.23...v0.1.24) (2026-03-30)


### Features

* add Copy Session .jsonl Path to card actions menu ([5d32d04](https://github.com/langwatch/kanban-code/commit/5d32d040ea11569d0c0169f0e04f5fd3a339bee6))
* context usage donut chart via Claude Code statusline ([93c4a65](https://github.com/langwatch/kanban-code/commit/93c4a656042f05cdd394ec388ab0230659375f00))
* message timestamps on hover, prompt history cycling, fix project cache ([ba27a13](https://github.com/langwatch/kanban-code/commit/ba27a137d53249830346da33dd86e71270b13fb3))
* show tab names in Process Manager, navigate to specific terminal tab ([09ff183](https://github.com/langwatch/kanban-code/commit/09ff183b950c94a35802d098ef3dad1ca43e9076))


### Bug Fixes

* absorb shell tab sessions into parent card instead of creating duplicates ([4d01339](https://github.com/langwatch/kanban-code/commit/4d01339a704ba4ba2c5e3afbd170994ad46f7ab8))
* activity detection after Stop, merge assistant turns, show thinking blocks ([545f297](https://github.com/langwatch/kanban-code/commit/545f29789b77874d74ec6d7a774684202bafe9ec))
* Add Link menu item visible in all card menus, not just expanded toolbar ([16f8595](https://github.com/langwatch/kanban-code/commit/16f8595edf7ff751ba9d1c56ec4d8db8df235e69))
* add Merge label pill to list view drag-and-drop (matches kanban) ([70de4a1](https://github.com/langwatch/kanban-code/commit/70de4a120816c70c6a3f805775531c9c10758a9e))
* derive current context tokens from percentage × window size ([c32a64d](https://github.com/langwatch/kanban-code/commit/c32a64d577b4bef5be96317031de65db98dd683f))
* empty statusline output, smaller gray donut chart ([16defe6](https://github.com/langwatch/kanban-code/commit/16defe63439facf24b50d6dc2544f736df22fabc))
* merge duplicate sessionId cards from launch race condition ([5fc19ab](https://github.com/langwatch/kanban-code/commit/5fc19abbd91df2f322e06523d843d5b446120223))
* PR number thousand separator, restore Unlink PR in toolbar menu ([55d82f3](https://github.com/langwatch/kanban-code/commit/55d82f3cba81b896db655e7a79b484e4392a595f))
* rename action not working from context menus ([c6d3ae0](https://github.com/langwatch/kanban-code/commit/c6d3ae0de90854f194a25e5b8f8eac88ac071611))
* search overlay invisible items, render markdown tables in chat ([9c31561](https://github.com/langwatch/kanban-code/commit/9c3156154688187f84fc06dc5e2377e200d053da))
* tiny ellipsis button, add card merge to list/sidebar view ([730f03f](https://github.com/langwatch/kanban-code/commit/730f03f228a9b88d216bc74f9d2efab9292e5344))
* worktree session not matching manual card, same-column merge blocked ([8fe056a](https://github.com/langwatch/kanban-code/commit/8fe056a10e0bcbf099cdcc85e8ca09a8d9678598))


### Performance

* fix search overlay slowness from VStack, scroll to top on query change ([72f5420](https://github.com/langwatch/kanban-code/commit/72f5420b09113fd4b19f1fdfab38779299c991df))


### Refactoring

* unify all card context menus into shared CardActionsMenu ([ac6233d](https://github.com/langwatch/kanban-code/commit/ac6233d5f83f5b5299fd5474bf46fd3ab84e048d))

## [0.1.23](https://github.com/langwatch/kanban-code/compare/v0.1.22...v0.1.23) (2026-03-22)


### Features

* add in-page browser DevTools via Eruda ([bd709af](https://github.com/langwatch/kanban-code/commit/bd709af4b6f0cd1a252711f161f656bf74f9ba03))
* add in-page browser DevTools via Eruda ([d8a332b](https://github.com/langwatch/kanban-code/commit/d8a332b440bdf17421e208a9e0b3d438cb961a58))
* read plan approval options from tmux pane instead of hardcoding ([14555f3](https://github.com/langwatch/kanban-code/commit/14555f37a57b3b55a99371b818fe2e317b4f941b))


### Bug Fixes

* Add Link in expanded mode, auto-expand last tool call, terminal flicker ([8480f6c](https://github.com/langwatch/kanban-code/commit/8480f6c798c801712bcaadd4d4a43e6258b94ed3))
* auto-expand last tool call, scroll on expand, busy indicator, prompt retry ([8d65216](https://github.com/langwatch/kanban-code/commit/8d65216fe5cd445d94fafae10edf26227da1678d))
* auto-expand uses filtered last turn, fix terminal flicker on card switch ([c1dea9a](https://github.com/langwatch/kanban-code/commit/c1dea9aacf228d6d4b9c2e5edd63e69c0de98432))
* browser tab scroll not intercepted by terminal scroll handler ([2929e65](https://github.com/langwatch/kanban-code/commit/2929e6570637d9f8cfb6f1932d63d614ecbfa419))
* clear browser tab selection when new shell tab is created ([d8a3445](https://github.com/langwatch/kanban-code/commit/d8a34458aaef9f370535eb6f19bd30c9ab22b844))
* Cmd+1-9 tab switching includes browser tabs, fix image popover ([3c26593](https://github.com/langwatch/kanban-code/commit/3c2659300932a92535d4c6aa3a3bf357a0167443))
* Cmd+W closes browser tabs too, not just shell tabs ([07ace67](https://github.com/langwatch/kanban-code/commit/07ace670be091a881b410269668cbde19a68d69e))
* dismiss stale pending message on chat view appear ([5756342](https://github.com/langwatch/kanban-code/commit/5756342eafbff5d4741717052f52928d1bb06e58))
* plan options missing, search perf, scroll on auto-expand ([a68e885](https://github.com/langwatch/kanban-code/commit/a68e885ce431debb4f9082e6287aac926848afc6))
* remember per-card tab selection, fix stale chat on switch, fix unsent prompts ([5405dad](https://github.com/langwatch/kanban-code/commit/5405dadec6424c63ec2f5ff49d36a361df807b71))
* resolve unused variable and return statement warnings ([f72a470](https://github.com/langwatch/kanban-code/commit/f72a470023e16c65fe8ffc2d24ad70eee37e2bd6))
* tab click delay, chat scroll perf, expanded terminal focus ([cfa009d](https://github.com/langwatch/kanban-code/commit/cfa009d0999540a8b2cb0a3e3c470d061fc322ac))
* validate restored tab selection against live sessions ([02ad278](https://github.com/langwatch/kanban-code/commit/02ad278fb4cfec29d86f8c5dd272f7c3783b2f47))


### Performance

* adaptive polling — fast when busy, idle when idle ([5109718](https://github.com/langwatch/kanban-code/commit/5109718cc24fdb404e90099d010ce07c2053f164))
* cache selectedCard to avoid CardDetailView re-renders ([0f444c3](https://github.com/langwatch/kanban-code/commit/0f444c38231b3a38cf91ebea2dbe76e2e9f63ea6))
* fine-grained SwiftUI re-renders via @Observable AppState ([903bfb9](https://github.com/langwatch/kanban-code/commit/903bfb9739aa7906c68092cc0cf0332341334e2b))
* instant terminal response for typing and cursor movement ([17cc0f0](https://github.com/langwatch/kanban-code/commit/17cc0f0fac90b80c0d0abe8fddc1d0f593677c0a))
* pre-compute per-column card arrays for independent observation ([8f79d6f](https://github.com/langwatch/kanban-code/commit/8f79d6ff334095f68d01ef67c107f1781bfaa7c5))


### Refactoring

* extract content tabs and PR helpers from CardDetailView ([787600b](https://github.com/langwatch/kanban-code/commit/787600b594a299c9703808c5eedb508a3c8d0393))
* extract launch, sync, and worktree logic from ContentView ([75bac83](https://github.com/langwatch/kanban-code/commit/75bac836f6763b11e992bc788dbabe337108fc69))
* split ChatView.swift and CardDetailView.swift into smaller cohesive files ([8766ccd](https://github.com/langwatch/kanban-code/commit/8766ccddb88ffbf7444924c74f4e05a1e0b3ae08))


### Documentation

* add productive-mode screenshot, project's goal and testimonials to README ([ce34c28](https://github.com/langwatch/kanban-code/commit/ce34c2807380b4fdf790a9ca2c17fa2ad5c54fe4))

## [0.1.22](https://github.com/langwatch/kanban-code/compare/v0.1.21...v0.1.22) (2026-03-19)


### Bug Fixes

* crash in SystemTray.terminate, pending message dedup, lazy image preview ([edc211d](https://github.com/langwatch/kanban-code/commit/edc211d227440aa9a1449edc2879f100978e9df2))
* cross-bubble text selection and line spacing in chat mode ([45417f6](https://github.com/langwatch/kanban-code/commit/45417f6812c5f939d5a2a633853c629dd617cdae))
* dismiss pending message when any new user turn arrives ([191a230](https://github.com/langwatch/kanban-code/commit/191a2307422e93788b442f233ca64a752a292a12))
* image hover loading reads line incrementally instead of entire file ([56e413c](https://github.com/langwatch/kanban-code/commit/56e413c6b901c6d664ed9e453d8ac8ebfca85932))
* lid-closed pushover skips when external display active, cross-bubble text selection ([b1fd8f4](https://github.com/langwatch/kanban-code/commit/b1fd8f4e9c32f80724699939f89add082b127da0))


### Performance

* passthrough mode for tmux copy-mode, less aggressive frame dropping ([6cf7829](https://github.com/langwatch/kanban-code/commit/6cf78291e20e0507111e2eb932d565cb34daac7d))

## [0.1.21](https://github.com/langwatch/kanban-code/compare/v0.1.20...v0.1.21) (2026-03-18)


### Features

* chat search, scroll fix, image thumbnails, worktree removal ([0f73c47](https://github.com/langwatch/kanban-code/commit/0f73c47291163190c8258964ae651ce4d4bdbf16))
* lid-closed pushover, per-project worktree pref, tab & scroll fixes ([80e2c61](https://github.com/langwatch/kanban-code/commit/80e2c61da667f47613bc436b2015d2339161aeb2))
* pushover lid-closed mode, per-project worktree pref, UI fixes ([f74995b](https://github.com/langwatch/kanban-code/commit/f74995bb815a3fef498fdde68886806ac1a9b314))


### Bug Fixes

* persist browser tabs across card switches ([15a1d52](https://github.com/langwatch/kanban-code/commit/15a1d5257502fdc56960d40a92b8c806fef3abf3))
* persist browser tabs across card switches ([f9d9af5](https://github.com/langwatch/kanban-code/commit/f9d9af58abfba18c13b14653acfe8ec916650bee))
* resolve compiler warnings from contributor PR ([17c4eb3](https://github.com/langwatch/kanban-code/commit/17c4eb34ab1914503f08691830cad0667e95339b))
* task notifications parsed from XML, rendered as centered system messages ([31b30df](https://github.com/langwatch/kanban-code/commit/31b30df8867032bfb5368959f2afc19fb9f8ddeb))

## [0.1.20](https://github.com/langwatch/kanban-code/compare/v0.1.19...v0.1.20) (2026-03-17)


### Features

* add embedded browser tabs to card detail view ([f901780](https://github.com/langwatch/kanban-code/commit/f90178079f6c6cc7245a9fdfe506ab849df28d2f))
* add embedded browser tabs to card detail view ([2de5322](https://github.com/langwatch/kanban-code/commit/2de5322f47c6cc7f6c8e1982f50c84382cb5f592))
* auto-scroll on expand, instant scroll to bottom ([e4b71a8](https://github.com/langwatch/kanban-code/commit/e4b71a80c359ad5d18a77441194b837277155da9))
* card info section in expanded mode actions menu ([a3b1c9a](https://github.com/langwatch/kanban-code/commit/a3b1c9ae9671a6122f3b770490955ab486f55cae))
* chat UX improvements, queue prompt from input, drag-reorder queued prompts ([78d2786](https://github.com/langwatch/kanban-code/commit/78d27868a999948d980ee375a91cd7a585921d65))
* grouped tool calls, image labels, queue fixes, escape behavior, prompt state ([e9e3a4c](https://github.com/langwatch/kanban-code/commit/e9e3a4c0d2f0262fd1a4989da16ad42c7ac6287c))
* image chips on user bubbles, up-arrow history, working indicator grace period ([af71be0](https://github.com/langwatch/kanban-code/commit/af71be0eb2dc9f35e4d8b92b442f5a1759ef3a04))
* interactive plan approval and AskUserQuestion in chat view ([7dbe248](https://github.com/langwatch/kanban-code/commit/7dbe2488aa82c2dbf5be65972090035f36a2701a))
* native Chat View with terminal toggle (Phase 1-5) ([677708c](https://github.com/langwatch/kanban-code/commit/677708c42eb0c0b4eaa86a558d56baa731492f68))
* queue prompt button in chat view, edit diff stats, spinner fix ([9aea657](https://github.com/langwatch/kanban-code/commit/9aea6572daef9d8054fbefb01846dbae5e85e9af))
* render subagents, plan mode, AskUserQuestion in chat view ([32e6e26](https://github.com/langwatch/kanban-code/commit/32e6e26e869e69cc278b4eca7a1c5e41f60b5c08))


### Bug Fixes

* chat view stability, prompt sending, path encoding, performance ([c60dfb7](https://github.com/langwatch/kanban-code/commit/c60dfb7859fc308ca2eabb17c9c0f027a5a416ae))
* checkpoint kills session, refreshes chat, LazyVStack blank screen ([f2b43a1](https://github.com/langwatch/kanban-code/commit/f2b43a191bd4a3023bcced60fb43089453fb84fe))
* hide sidebar toggle in kanban mode, center search overlay on full window ([494f286](https://github.com/langwatch/kanban-code/commit/494f2861c7ff859daec07d772302904e764d924d))
* per-card chat drafts, scroll reliability, prompt sending retry ([efaed0b](https://github.com/langwatch/kanban-code/commit/efaed0b699106b033a454ea68251ea0aa41b571b))
* project selector always visible in toolbar, compact sync icon in expanded mode ([6e2bce2](https://github.com/langwatch/kanban-code/commit/6e2bce2a3acaa72af1db76648e190c6c99332a3d))
* prompt editor state isolation per card, clear pending on card switch ([388b179](https://github.com/langwatch/kanban-code/commit/388b179d1bdf8263bf51ee2edff71d25d700f52d))


### Performance

* fork SwiftTerm async dispatch, off-main-actor history loading ([d4a131e](https://github.com/langwatch/kanban-code/commit/d4a131e6b2ae5b79ff524965cd110a9c95f51832))
* wait-for-silence terminal rendering, always drop to tail ([0bbcd60](https://github.com/langwatch/kanban-code/commit/0bbcd60a049c365fde8c43ffd5da9c1dac93203d))
* wait-for-silence terminal rendering, always drop to tail ([d5262f3](https://github.com/langwatch/kanban-code/commit/d5262f37fb97e4db3eb615082a52dc3a78fd27e5))


### Refactoring

* enrich ContentBlock for chat view (Phase 0) ([cc12243](https://github.com/langwatch/kanban-code/commit/cc122431c5de5dfeaafde302e95e83f50f2dd9d2))
* global dialog state (Elm-like) for all card action dialogs ([c29a463](https://github.com/langwatch/kanban-code/commit/c29a463f34d905dcdc3f6670c29d0e273e0541db))

## [0.1.19](https://github.com/langwatch/kanban-code/compare/v0.1.18...v0.1.19) (2026-03-15)


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
* NavigationSplitView sidebar, Finder-style terminal tabs, list view redesign ([296c68f](https://github.com/langwatch/kanban-code/commit/296c68f751bd308db73773416251640a2bc6288e))
* Parse inline markdown in session history assistant turns ([d0cbb9d](https://github.com/langwatch/kanban-code/commit/d0cbb9d6f4bf36d1e17e9fa4d0cd5ee092d92d7e))
* Parse inline markdown in session history assistant turns ([a77839f](https://github.com/langwatch/kanban-code/commit/a77839f56d8b5cd0493992602e286fa6550d5600))
* persist expanded mode, board split, and list section collapse ([bcaef03](https://github.com/langwatch/kanban-code/commit/bcaef035fc9cd5788294fed377c5c89344485b50))
* remove expand/contract buttons, close-button hover, persist card selection ([d2df9a6](https://github.com/langwatch/kanban-code/commit/d2df9a6faafa2a96d8755977060088dd0c66c447))
* terminal tab folder names, Cmd+W close tab, Cmd+T focus ([4cb7884](https://github.com/langwatch/kanban-code/commit/4cb78847b2423f4737fee746a2363395ec280428))
* terminal tab rename, per-project remote toggle, worktree branch input ([b09dd97](https://github.com/langwatch/kanban-code/commit/b09dd97a5f30faf655981e6999701a188dcc2c68))
* transform search overlay into VS Code-style command palette ([ab35bea](https://github.com/langwatch/kanban-code/commit/ab35beaafd613e18880e008c6d6cedc2109eecb0))
* unify list mode and expanded mode into single view toggle ([f15ced7](https://github.com/langwatch/kanban-code/commit/f15ced7d03075802e866ee0566c76f9132b041b3))
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
* eliminate launch flicker by restoring state synchronously in init ([688cebf](https://github.com/langwatch/kanban-code/commit/688cebfa9eeeba5d643c84346ad34fb8ab6f5392))
* eliminate terminal flicker with time-budgeted batch feeding ([6dc9eb8](https://github.com/langwatch/kanban-code/commit/6dc9eb8aaf647fa359fb8b66f0f0f6c25a749c62))
* optimize reconciliation loop from ~1s to ~0.4s ([7c0a098](https://github.com/langwatch/kanban-code/commit/7c0a0986cd1ef9323a8aa938c13c085e5e2324e8))
* tune terminal batching for 1M context sessions ([57635bc](https://github.com/langwatch/kanban-code/commit/57635bca69a950827a08aaf0c732ef4b59dc4375))


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
