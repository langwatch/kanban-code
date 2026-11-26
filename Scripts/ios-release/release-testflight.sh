#!/bin/zsh
# Usage: Scripts/ios-release/release-testflight.sh [git-ref] [--profile <App Store .mobileprovision>]
#        (ref default origin/main; it must be pushed)
# Ships Kanban Code iOS to TestFlight. GitHub's Xcode 27 runner archives the
# app unsigned (the iOS 27.1+ SDK, so iPhone Duo gives it the whole display),
# then this Mac signs it with the team's Apple Distribution identity, uploads
# it and waits until App Store Connect has processed it. Adapted from Laze's
# apps/ios/scripts/release/release-testflight.sh.
# Keys come from kv laze/prod (ASC_KEY_*, IOS_DIST_P12_*) at run time; none is
# left on disk after. KC_IOS_RELEASE_DIR keeps the runs.
set -euo pipefail
HERE=${0:A:h}
REPO=$(git -C $HERE rev-parse --show-toplevel)
REF=origin/main
PROFILE=""
while (( $# )); do
  case $1 in
    --profile) PROFILE=${2:A}; shift 2 ;;
    *) REF=$1; shift ;;
  esac
done
TEAM=XC2B8QXW6P
BUNDLE=io.kanbancode.mobile
GH_REPO=langwatch/kanban-code
A=${KC_IOS_RELEASE_DIR:-$REPO/.claude/tmp/ios-release}
BUILD=$(date +%Y%m%d%H%M)
RUN=$A/run-$BUILD
# Two runs in one minute would share a run folder and delete each other's key on exit.
mkdir -p $A
mkdir $RUN 2>/dev/null || { echo "a release run already started this minute ($RUN); start again in a minute" >&2; exit 1; }
umask 077
export P8=$RUN/AuthKey.p8
cleanup() { /bin/rm -f $P8 $RUN/asc.env $RUN/dist.p12 $RUN/private_keys/AuthKey_*.p8 }
trap cleanup EXIT
log() { echo "[$(date +%H:%M:%S)] $*" }

git -C $REPO fetch -q origin
SHA=$(git -C $REPO rev-parse "$REF")
git -C $REPO branch -r --contains $SHA | grep -q . || { log "$SHA is not on GitHub; push it first"; exit 1; }
log "ref $REF ($SHA) -> build $BUILD"

kv run laze/prod/ASC_KEY_P8 laze/prod/ASC_KEY_ID laze/prod/ASC_ISSUER_ID --reason "Upload a Kanban Code iOS build to TestFlight" -- node -e '
  const fs = require("fs"), e = (n) => process.env["laze/prod/" + n] ?? process.env[n];
  fs.writeFileSync(process.argv[1], e("ASC_KEY_P8"), { mode: 0o600 });
  fs.writeFileSync(process.argv[2], `ASC_KEY_ID=${e("ASC_KEY_ID")}\nASC_ISSUER_ID=${e("ASC_ISSUER_ID")}\n`, { mode: 0o600 });' $P8 $RUN/asc.env
set -a; source $RUN/asc.env; set +a

# App ID, push capability, App Store profile, app record and tester group.
if [[ -n $PROFILE ]]; then
  cp $PROFILE $RUN/app.mobileprovision
  OUTPUT=$(node $HERE/ensure-app.mjs $RUN --app-only)
else
  OUTPUT=$(node $HERE/ensure-app.mjs $RUN)
fi
APP_ID=${${(M)OUTPUT:#APP_ID=*}#APP_ID=}
[[ -n $APP_ID ]] || { log "no app id"; exit 1; }

# Distribution identity: import from kv when the keychain does not have it.
if ! security find-identity -v -p codesigning | grep -q "Apple Distribution: .*($TEAM)"; then
  log "importing distribution identity from kv"
  kv get laze/prod/IOS_DIST_P12_B64 --reason "Sign a Kanban Code iOS build for TestFlight" | base64 -d > $RUN/dist.p12
  PW=$(kv get laze/prod/IOS_DIST_P12_PASSWORD --reason "Sign a Kanban Code iOS build for TestFlight")
  security import $RUN/dist.p12 -k ~/Library/Keychains/login.keychain-db -P "$PW" -T /usr/bin/codesign
fi
IDENTITY=$(security find-identity -v -p codesigning | sed -n "s/.*\"\(Apple Distribution: .*($TEAM)\)\"/\1/p" | head -1)

log "archiving on GitHub with Xcode 27"
STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
gh workflow run ios.yml -R $GH_REPO --ref main -f build=$BUILD -f sha=$SHA
GH_RUN=""
for i in $(seq 1 30); do
  GH_RUN=$(gh run list -R $GH_REPO -w ios.yml -e workflow_dispatch -L 10 --json databaseId,createdAt \
    -q "[.[] | select(.createdAt >= \"$STARTED\")] | last | .databaseId" 2>/dev/null || true)
  [[ -n $GH_RUN && $GH_RUN != null ]] && break
  sleep 5
done
[[ -n $GH_RUN && $GH_RUN != null ]] || { log "the workflow run did not start"; exit 1; }
log "run https://github.com/$GH_REPO/actions/runs/$GH_RUN"
gh run watch $GH_RUN -R $GH_REPO --exit-status --interval 30 > $RUN/ci.log 2>&1 || { tail -20 $RUN/ci.log; log "CI run failed"; exit 1; }
gh run download $GH_RUN -R $GH_REPO -n ios-archive-$BUILD -D $RUN
ditto -x -k $RUN/KanbanCodeMobile.xcarchive.zip $RUN
APP=$RUN/Payload/KanbanCodeMobile.app
mkdir -p $RUN/Payload
ditto $RUN/KanbanCodeMobile.xcarchive/Products/Applications/KanbanCodeMobile.app $APP
SDK=$(/usr/libexec/PlistBuddy -c "Print :DTSDKName" $APP/Info.plist)
log "built with $(/usr/libexec/PlistBuddy -c 'Print :DTXcode' $APP/Info.plist) against $SDK"
[[ $SDK == iphoneos27.<1->* || $SDK == iphoneos<28->.* ]] || { log "refusing: $SDK is older than iOS 27.1, iPhone Duo would letterbox it"; exit 1; }
[[ $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" $APP/Info.plist) == $BUILD ]] || { log "archive has another build number"; exit 1; }

log "signing with $IDENTITY"
python3 -I $HERE/entitlements.py $RUN/app.mobileprovision $REPO/Apps/iOS/KanbanCodeMobile/KanbanCodeMobile.entitlements \
  $RUN/entitlements.plist
cp $RUN/app.mobileprovision $APP/embedded.mobileprovision
if [[ -d $APP/Frameworks ]]; then
  for f in $APP/Frameworks/*(N); do codesign -f -s "$IDENTITY" --timestamp=none $f; done
fi
for x in $APP/PlugIns/*.appex(N); do
  log "refusing: $x needs its own profile, which this script does not make yet"; exit 1
done
codesign -f -s "$IDENTITY" --entitlements $RUN/entitlements.plist --generate-entitlement-der $APP
codesign --verify --deep --strict $APP
codesign -d --entitlements - --xml $APP > $RUN/signed-entitlements.plist 2>/dev/null
grep -q "aps-environment" $RUN/signed-entitlements.plist || { log "signed app lacks aps-environment"; exit 1; }
for key in NSFaceIDUsageDescription NSCameraUsageDescription; do
  /usr/libexec/PlistBuddy -c "Print :$key" $APP/Info.plist >/dev/null 2>&1 || { log "missing $key in Info.plist"; exit 1; }
done
(cd $RUN && /usr/bin/zip -qry KanbanCodeMobile.ipa Payload)

log "uploading"
mkdir -p $RUN/private_keys
cp $P8 $RUN/private_keys/AuthKey_$ASC_KEY_ID.p8
API_PRIVATE_KEYS_DIR=$RUN/private_keys xcrun altool --upload-app -f $RUN/KanbanCodeMobile.ipa -t ios \
  --apiKey $ASC_KEY_ID --apiIssuer $ASC_ISSUER_ID > $RUN/upload.log 2>&1 || { tail -30 $RUN/upload.log; exit 1; }

log "waiting for processing"
for i in $(seq 1 90); do
  OUT=$RUN/b.json node $HERE/asc.mjs GET "/v1/builds?filter[app]=$APP_ID&filter[version]=$BUILD&include=buildBetaDetail" >/dev/null || true
  ST=$(python3 -I -c "
import json,sys;d=json.load(open(sys.argv[1]))
b=d.get('data');inc=d.get('included',[])
if b is None: print('api-error'); raise SystemExit
print('none' if not b else b[0]['attributes']['processingState']+' '+(inc[0]['attributes']['internalBuildState'] if inc else '-'))" $RUN/b.json)
  echo "  $ST"
  [[ "$ST" == VALID* || "$ST" == INVALID* || "$ST" == FAILED* ]] && break
  sleep 20
done
[[ "$ST" == VALID* ]] || { log "build $BUILD not valid: $ST"; exit 1; }
log "DONE build $BUILD from $SHA: $ST"
