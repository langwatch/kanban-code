#!/bin/bash
# Keeps Kanban Code Mobile installed on a paired iPhone: reinstalls it when
# the app is missing, when its provisioning profile ends within RENEW_DAYS
# (FREE_RENEW_DAYS for a free team's 7-day profile), or when the iOS sources
# changed since the last install.
# Run by the LaunchAgent from `make ios-autoinstall`, or by hand with --force
# (which also launches the app).
#
# Team: KC_IOS_TEAM, else a paid team Xcode is signed in to, else a free
# personal team. A free team signs io.kanbancode.mobile.dev, since the App ID
# io.kanbancode.mobile belongs to the paid team; KC_IOS_BUNDLE_ID_SUFFIX
# overrides the suffix. Both can be set in ~/.kanban-code/ios-device/config,
# which is sourced, so the LaunchAgent reads them too.
set -uo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
RENEW_DAYS=${RENEW_DAYS:-7}
FREE_RENEW_DAYS=${FREE_RENEW_DAYS:-2}
STATE_DIR="$HOME/.kanban-code/ios-device"
LOG="$HOME/.kanban-code/logs/ios-device-refresh.log"
DERIVED="$REPO/.build/ios-device"
APP="$DERIVED/Build/Products/Debug-iphoneos/KanbanCodeMobile.app"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

mkdir -p "$STATE_DIR" "$(dirname "$LOG")"
# shellcheck source=/dev/null
[ -f "$STATE_DIR/config" ] && . "$STATE_DIR/config"
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

# Paired physical iPhones on USB or on the same Wi-Fi, never simulators or
# the Mac. A Wi-Fi one may be asleep or away; the first call to it below
# tells.
xcrun devicectl list devices --json-output "$TMP/devices.json" >/dev/null 2>&1 || exit 0
DEVICES=$(python3 - "$TMP/devices.json" <<'EOF'
import json, sys
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    c, h = d.get("connectionProperties", {}), d.get("hardwareProperties", {})
    if h.get("platform") == "iOS" and h.get("reality") == "physical" and h.get("deviceType") == "iPhone" \
        and c.get("pairingState") == "paired" and (
        c.get("tunnelState") == "connected" or c.get("transportType") in ("localNetwork", "wired")):
        print(h["udid"])
EOF
)
[ -z "$DEVICES" ] && exit 0

# The development team: KC_IOS_TEAM, else the teams of the accounts Xcode is
# signed in to, a paid one first.
TEAM=${KC_IOS_TEAM:-}
FREE=0
if [ -z "$TEAM" ]; then
  defaults export com.apple.dt.Xcode "$TMP/xcode.plist" 2>/dev/null
  read -r TEAM FREE < <(python3 - "$TMP/xcode.plist" <<'EOF'
import plistlib, sys
try:
    accounts = plistlib.load(open(sys.argv[1], "rb")).get("IDEProvisioningTeamByIdentifier", {})
    teams = [t for ts in accounts.values() for t in ts]
except Exception:
    teams = []
teams.sort(key=lambda t: bool(t.get("isFreeProvisioningTeam")))
if teams:
    print(teams[0]["teamID"], int(bool(teams[0].get("isFreeProvisioningTeam"))))
EOF
)
  TEAM=${TEAM:-}; FREE=${FREE:-0}
fi
if [ -n "${KC_IOS_BUNDLE_ID_SUFFIX+set}" ]; then SUFFIX=$KC_IOS_BUNDLE_ID_SUFFIX
elif [ "$FREE" = 1 ]; then SUFFIX=.dev
else SUFFIX=""; fi
BUNDLE_ID=io.kanbancode.mobile$SUFFIX
[ "$FREE" = 1 ] && RENEW_DAYS=$FREE_RENEW_DAYS

# Signed out of Xcode, a profile for the app still on disk names the team
# and signs the build until it ends.
if [ -z "$TEAM" ]; then
  for profile in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"/*.mobileprovision; do
    [ -f "$profile" ] || continue
    security cms -D -i "$profile" >"$TMP/profile.plist" 2>/dev/null || continue
    app_id=$(plutil -extract Entitlements.application-identifier raw "$TMP/profile.plist" 2>/dev/null)
    ends=$(plutil -extract ExpirationDate raw "$TMP/profile.plist" 2>/dev/null)
    if [ "${app_id#*.}" = "$BUNDLE_ID" ] && [[ "$ends" > "$(date -u +%FT%TZ)" ]]; then
      TEAM=${app_id%%.*}
      break
    fi
  done
fi
if [ -z "$TEAM" ]; then log "no development team in Xcode; sign in under Xcode > Settings > Apple Accounts"; exit 1; fi

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
    reason=$(python3 - "$STATE" "$RENEW_DAYS" "$SOURCES" "$BUNDLE_ID" <<'EOF'
import json, sys, datetime as dt
s = json.load(open(sys.argv[1]))
left = dt.datetime.fromisoformat(s["expires"].replace("Z", "+00:00")) - dt.datetime.now(dt.timezone.utc)
if s.get("bundleId", "io.kanbancode.mobile") != sys.argv[4]:
    print("first install of " + sys.argv[4])
elif left < dt.timedelta(days=int(sys.argv[2])):
    print(f"profile ends {s['expires']}")
elif s.get("sources") != sys.argv[3]:
    print("iOS sources changed")
EOF
)
  elif [ -z "$reason" ]; then
    reason="first install by this job"
  fi
  [ -z "$reason" ] && continue

  log "$UDID: reinstalling $BUNDLE_ID with team $TEAM ($reason)"
  if [ $built = 0 ]; then
    (cd "$REPO/Apps/iOS" && xcodegen generate --quiet) >>"$LOG" 2>&1
    if ! COMPILATION_CACHE_ENABLE_CACHING=NO xcodebuild -project "$REPO/Apps/iOS/KanbanCodeMobile.xcodeproj" \
        -scheme KanbanCodeMobile -destination "platform=iOS,id=$UDID" -derivedDataPath "$DERIVED" \
        -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
        DEVELOPMENT_TEAM="$TEAM" KC_BUNDLE_ID_SUFFIX="$SUFFIX" COMPILATION_CACHE_ENABLE_CACHING=NO \
        build >"$TMP/build.log" 2>&1; then
      grep -E 'error' "$TMP/build.log" | grep -v DVTDevice | head -5 >>"$LOG"
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
  printf '{"expires":"%s","sources":"%s","bundleId":"%s","team":"%s","installedAt":"%s"}\n' \
    "$expires" "$SOURCES" "$BUNDLE_ID" "$TEAM" "$(date -u +%FT%TZ)" >"$STATE"
  log "$UDID: installed $BUNDLE_ID, profile ends $expires"
  notify "Reinstalled on the iPhone ($reason)"
  if [ $FORCE = 1 ] && ! xcrun devicectl device process launch --device "$UDID" --terminate-existing "$BUNDLE_ID" >>"$LOG" 2>&1; then
    log "$UDID: launch failed; if iOS says the developer is not trusted, trust it under Settings > General > VPN & Device Management"
  fi
done
