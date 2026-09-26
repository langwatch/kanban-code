#!/bin/bash
# Keeps Kanban Code Mobile installed on a paired iPhone: reinstalls it when
# the app is missing, when its provisioning profile ends within
# RENEW_DAYS, or when the iOS sources changed since the last install.
# Run by the LaunchAgent from `make ios-autoinstall`, or by hand with --force.
set -uo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
BUNDLE_ID=io.kanbancode.mobile
RENEW_DAYS=${RENEW_DAYS:-7}
STATE_DIR="$HOME/.kanban-code/ios-device"
LOG="$HOME/.kanban-code/logs/ios-device-refresh.log"
DERIVED="$REPO/.build/ios-device"
APP="$DERIVED/Build/Products/Debug-iphoneos/KanbanCodeMobile.app"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

mkdir -p "$STATE_DIR" "$(dirname "$LOG")"
log() { echo "[$(date -u +%FT%TZ)] $*" >>"$LOG"; [ -t 1 ] && echo "$*"; }
notify() { osascript -e "display notification \"$1\" with title \"Kanban Code Mobile\"" >/dev/null 2>&1; }

LOCK="$STATE_DIR/lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  # A lock older than an hour is left over from a killed run.
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +60 2>/dev/null)" ]; then rmdir "$LOCK"; mkdir "$LOCK" || exit 0; else exit 0; fi
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

TMP=$(mktemp -d "$STATE_DIR/run.XXXX")
trap 'rmdir "$LOCK" 2>/dev/null; /bin/rm -r "$TMP"' EXIT

# Paired iPhones on USB or on the same Wi-Fi. A Wi-Fi one may be asleep or
# away; the first call to it below tells.
xcrun devicectl list devices --json-output "$TMP/devices.json" >/dev/null 2>&1 || exit 0
DEVICES=$(python3 - "$TMP/devices.json" <<'EOF'
import json, sys
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    c, h = d.get("connectionProperties", {}), d.get("hardwareProperties", {})
    if h.get("platform") == "iOS" and c.get("pairingState") == "paired" and (
        c.get("tunnelState") == "connected" or c.get("transportType") == "localNetwork"):
        print(h["udid"])
EOF
)
[ -z "$DEVICES" ] && exit 0

# The development team Xcode signed in with; KC_IOS_TEAM overrides.
TEAM=${KC_IOS_TEAM:-$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null | sed -n 's/.*teamID = \([A-Z0-9]*\);/\1/p' | head -1)}
if [ -z "$TEAM" ]; then log "no development team in Xcode; sign in under Xcode > Settings > Accounts"; exit 1; fi

SOURCES=$(git -C "$REPO" log -1 --format=%H -- Apps/iOS Sources/KanbanCodeRemoteKit LocalPackages/SwiftTerm Package.swift Package.resolved)

built=0
for UDID in $DEVICES; do
  STATE="$STATE_DIR/$UDID.json"
  reason=""
  if [ $FORCE = 1 ]; then reason="forced"; fi
  /bin/rm -f "$TMP/apps.json"
  xcrun devicectl device info apps --device "$UDID" --bundle-id "$BUNDLE_ID" --timeout 25 \
    --json-output "$TMP/apps.json" >/dev/null 2>&1 || continue
  if [ -z "$reason" ]; then
    installed=$(python3 -c "import json;print(len(json.load(open('$TMP/apps.json'))['result']['apps']))" 2>/dev/null || echo 0)
    [ "$installed" = "0" ] && reason="not installed"
  fi
  if [ -z "$reason" ] && [ -f "$STATE" ]; then
    reason=$(python3 - "$STATE" "$RENEW_DAYS" "$SOURCES" <<'EOF'
import json, sys, datetime as dt
s = json.load(open(sys.argv[1]))
left = dt.datetime.fromisoformat(s["expires"].replace("Z", "+00:00")) - dt.datetime.now(dt.timezone.utc)
if left < dt.timedelta(days=int(sys.argv[2])):
    print(f"profile ends {s['expires']}")
elif s.get("sources") != sys.argv[3]:
    print("iOS sources changed")
EOF
)
  elif [ -z "$reason" ]; then
    reason="first install by this job"
  fi
  [ -z "$reason" ] && continue

  log "$UDID: reinstalling ($reason)"
  if [ $built = 0 ]; then
    (cd "$REPO/Apps/iOS" && xcodegen generate --quiet) >>"$LOG" 2>&1
    if ! xcodebuild -project "$REPO/Apps/iOS/KanbanCodeMobile.xcodeproj" -scheme KanbanCodeMobile \
        -destination "platform=iOS,id=$UDID" -derivedDataPath "$DERIVED" -allowProvisioningUpdates \
        DEVELOPMENT_TEAM="$TEAM" build >"$TMP/build.log" 2>&1; then
      grep -E 'error' "$TMP/build.log" | head -5 >>"$LOG"
      log "$UDID: build failed; the installed app is left as is"
      notify "Could not rebuild the app: see ~/.kanban-code/logs/ios-device-refresh.log"
      exit 1
    fi
    built=1
  fi
  if ! xcrun devicectl device install app --device "$UDID" --timeout 240 "$APP" >>"$LOG" 2>&1; then
    log "$UDID: install failed"
    notify "Could not install the app on the iPhone"
    continue
  fi
  expires=$(security cms -D -i "$APP/embedded.mobileprovision" 2>/dev/null | plutil -extract ExpirationDate raw -)
  printf '{"expires":"%s","sources":"%s","installedAt":"%s"}\n' "$expires" "$SOURCES" "$(date -u +%FT%TZ)" >"$STATE"
  log "$UDID: installed, profile ends $expires"
  notify "Reinstalled on the iPhone ($reason)"
done
