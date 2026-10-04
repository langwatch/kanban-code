# Kanban Code for iPhone

A remote control for Kanban Code. Sessions keep running on the machines that run them (masters: the Mac app, or `kanban-code-server` on an always-on Linux box); the phone shows the board, reads and sends to the conversation, starts tasks, and opens the card's terminal. The API it talks to is described in [docs/remote-control.md](../../docs/remote-control.md).

## Build and run in the simulator

```bash
make ios        # generate the Xcode project with XcodeGen and build for the simulator
make ios-run    # boot the iPhone 17 Pro simulator, install and launch
make ios-test   # UI tests that walk the flows against a running server
```

SwiftTerm compiles a Metal shader, so Xcode needs the Metal toolchain once: `xcodebuild -downloadComponent MetalToolchain`.

The UI tests need a server to talk to. Start the demo server and pass its pairing links:

```bash
swift build --product kanban-code-remote-demo
D=.claude/tmp/ios-demo
.build/debug/kanban-code-remote-demo --port 7790 --devices $D/devices.json --tmux-socket kc-demo \
  --machine "machine_mac:Rogerio's MacBook Pro" --pair iPhone &
.build/debug/kanban-code-remote-demo --port 7791 --devices $D/devices.json \
  --machine machine_box:rchaves-platform --cards box --foreign "machine_mac:Rogerio's MacBook Pro" \
  --pair agent --scope agent --exit-when "$PWD/$D/kill-box" &
TEST_RUNNER_KC_PAIR_LINK='kanbancode://pair?url=http://127.0.0.1:7790&token=<iPhone token>' \
TEST_RUNNER_KC_BOX_PAIR_LINK='kanbancode://pair?url=http://127.0.0.1:7791&token=<iPhone token>' \
TEST_RUNNER_KC_AGENT_PAIR_LINK='kanbancode://pair?url=http://127.0.0.1:7790&token=<agent token>' \
TEST_RUNNER_KC_BOX_EXIT_FILE="$PWD/$D/kill-box" \
TEST_RUNNER_KC_SHOT_DIR="$PWD/$D" make ios-test
```

The two demos are two masters, a Mac and a box, sharing one devices file, so each token works on both. `MultiMasterTests` pairs both and checks the merged board, per-card routing, launching on a chosen machine, and the box going offline (it writes the `--exit-when` file, which stops the box demo; restart it before the next run).

Pass links with `url=http://127.0.0.1:...`: the printed ones use the Tailscale address, which the Mac cannot reach from itself.

- `--tmux-socket kc-demo` makes the demo's tmux cards real tmux sessions on a server of their own (`tmux -L kc-demo`), which the terminal scroll test needs.
- The demo changes as the tests use it (queued prompts get sent), so restart it before a full run.
- The keyboard tests need the software keyboard: turn off Simulator > I/O > Keyboard > Connect Hardware Keyboard (`defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool false` before booting).
- The image test picks the first photo in the library: `xcrun simctl addmedia booted <png>` once.

`IOS_SIM="iPhone 17"` picks another simulator. The project file is generated from `project.yml` and not committed; run `make ios-project` after pulling.

To pair the simulator with a server on the same Mac:

```bash
xcrun simctl openurl booted 'kanbancode://pair?url=http://127.0.0.1:7790&token=kc_...&name=Studio'
```

Or skip the confirmation prompt by passing the link at launch:

```bash
SIMCTL_CHILD_KANBANCODE_PAIR_LINK='kanbancode://pair?...' xcrun simctl launch booted io.kanbancode.mobile
```

## Markdown in chat messages

`MarkdownText` in `Views/ChatPane.swift` draws assistant messages: fenced code, headings, lists, inline styles and tables.

A table is read by `MarkdownTable` in `Sources/KanbanCodeRemoteKit/MarkdownTable.swift` and drawn by `Views/MarkdownTableView.swift`:

- A header row, a separator row with as many cells, then rows until a blank line or a line with no pipe. A line with pipes and no separator row under it stays text.
- Column alignment comes from the separator row (`:---`, `:---:`, `---:`).
- A pipe inside a code span or written `\|` belongs to its cell.
- Short rows are filled with empty cells, long rows are cut.
- A separator row still being written at the end of a message already counts, so the header never shows as text first.
- Columns are as wide as their content. When that is wider than the chat, columns narrower than their share keep their width and the others wrap in what is left, never under 96 points. A table that cannot fit that way scrolls sideways on its own, with columns up to 220 points.
- Every cell is selectable text with inline markdown.

The Mac chat draws tables through MarkdownUI.

## Install on your iPhone

1. `make ios-project`, then open `Apps/iOS/KanbanCodeMobile.xcodeproj` in Xcode.
2. Select the KanbanCodeMobile target, Signing & Capabilities, and pick your team. A free personal team works (sign in under Xcode > Settings > Accounts). If the bundle id `io.kanbancode.mobile` is taken for your team, change it to something of your own.
3. Plug in the phone (or pair it over Wi-Fi in Window > Devices and Simulators), choose it as the run destination and press Run.
4. On the phone, turn on Settings > Privacy & Security > Developer Mode the first time, and trust your developer certificate under Settings > General > VPN & Device Management.

From the command line, with Xcode signed in to your Apple account: `make ios-device` builds and installs on every connected, paired iPhone.

`make ios-autoinstall` adds a LaunchAgent that runs `Scripts/ios-device-refresh.sh` every 10 minutes. When a paired iPhone is reachable (USB, or awake on the same Wi-Fi), it reinstalls the app if it is missing, if its provisioning profile ends within 7 days, or if the iOS sources changed since the last install. The log is `~/.kanban-code/logs/ios-device-refresh.log`. `make ios-autoinstall-remove` takes it out.

## Connect to the Mac

The Mac serves the API only on loopback and its Tailscale addresses, so the phone needs Tailscale on the same tailnet.

1. On the Mac, turn on Kanban Code > Settings > Remote Control, then Add device. It shows a QR code.
2. In the app, Scan QR code. Pasting the link or typing the URL and token works too.

Plain `http://100.x.y.z:7780` works (the app allows it on purpose). For HTTPS with a valid certificate, put Tailscale Serve in front of the server on the Mac:

```bash
tailscale serve --bg --https=7780 http://127.0.0.1:7780
```

and use `https://<mac>.<tailnet>.ts.net:7780` as the URL.

## Several machines

Pair every master: the Mac and an always-on box (`kanban-code-server pair iPhone` on the box prints its link). The board shows the cards of all of them, each named with the machine that runs it; a card's chat, prompts, queue and terminals go to that machine. The Machines button on the board shows which are online and picks the primary: the default machine for new tasks, and the one to keep always on. A machine that cannot be reached (a sleeping Mac, a Mac on a VPN that cuts it off the tailnet) keeps its last board on the phone, shown as offline since its last answer. Tokens are kept in the Keychain.
