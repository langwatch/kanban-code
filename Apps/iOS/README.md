# Kanban Code for iPhone

A remote control for Kanban Code on your Mac. Sessions keep running on the Mac; the phone shows the board, reads and sends to the conversation, starts tasks, and opens the card's terminal. The API it talks to is described in [docs/remote-control.md](../../docs/remote-control.md).

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
.build/debug/kanban-code-remote-demo --port 7790 --pair iPhone &
.build/debug/kanban-code-remote-demo --port 7791 --pair agent --scope agent --devices .claude/tmp/agent-devices.json &
TEST_RUNNER_KC_PAIR_LINK='<link printed on 7790>' \
TEST_RUNNER_KC_AGENT_PAIR_LINK='<link printed on 7791>' \
TEST_RUNNER_KC_SHOT_DIR="$PWD/.claude/tmp/ios-shots" make ios-test
```

`IOS_SIM="iPhone 17"` picks another simulator. The project file is generated from `project.yml` and not committed; run `make ios-project` after pulling.

To pair the simulator with a server on the same Mac:

```bash
xcrun simctl openurl booted 'kanbancode://pair?url=http://127.0.0.1:7790&token=kc_...&name=Studio'
```

Or skip the confirmation prompt by passing the link at launch:

```bash
SIMCTL_CHILD_KANBANCODE_PAIR_LINK='kanbancode://pair?...' xcrun simctl launch booted io.kanbancode.mobile
```

## Install on your iPhone

1. `make ios-project`, then open `Apps/iOS/KanbanCodeMobile.xcodeproj` in Xcode.
2. Select the KanbanCodeMobile target, Signing & Capabilities, and pick your team. A free personal team works (sign in under Xcode > Settings > Accounts). If the bundle id `io.kanbancode.mobile` is taken for your team, change it to something of your own.
3. Plug in the phone (or pair it over Wi-Fi in Window > Devices and Simulators), choose it as the run destination and press Run.
4. On the phone, turn on Settings > Privacy & Security > Developer Mode the first time, and trust your developer certificate under Settings > General > VPN & Device Management.

From the command line, with Xcode signed in to your Apple account: `make ios-device` builds and installs on every connected, paired iPhone.

`make ios-autoinstall` adds a LaunchAgent that runs `scripts/ios-device-refresh.sh` every 10 minutes. When an iPhone is connected (USB, or Wi-Fi once paired), it reinstalls the app if it is missing, if its provisioning profile ends within 7 days, or if the iOS sources changed since the last install. The log is `~/.kanban-code/logs/ios-device-refresh.log`. `make ios-autoinstall-remove` takes it out.

## Connect to the Mac

The Mac serves the API only on loopback and its Tailscale addresses, so the phone needs Tailscale on the same tailnet.

1. On the Mac, turn on Kanban Code > Settings > Remote Control, then Add device. It shows a QR code.
2. In the app, Scan QR code. Pasting the link or typing the URL and token works too.

Plain `http://100.x.y.z:7780` works (the app allows it on purpose). For HTTPS with a valid certificate, put Tailscale Serve in front of the server on the Mac:

```bash
tailscale serve --bg --https=7780 http://127.0.0.1:7780
```

and use `https://<mac>.<tailnet>.ts.net:7780` as the URL.

Several Macs can be paired; switch between them from the Macs menu on the board. Tokens are kept in the Keychain.
