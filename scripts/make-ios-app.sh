#!/usr/bin/env bash
# make-ios-app.sh — generate the iOS Xcode project and build the app + keyboard.
#
# SwiftPM can't produce iOS .app/.appex bundles, so the iOS side wraps the
# package in an XcodeGen spec (ios/project.yml — the .xcodeproj is gitignored
# and regenerated here on every run). Two modes:
#
#   (default)  unsigned compile-check against generic iOS hardware — proves the
#              app + keyboard extension compile and link. No Apple account, no
#              signing. This is what CI runs.
#   release    archive + upload to TestFlight, auto-bumping CFBundleVersion
#              per upload (docs/IOS-DISTRIBUTION.md). Requires Apple Developer
#              enrollment (phase i0 account steps still pending — see issue
#              #13) and these env vars:
#                WHISPR_DEV_TEAM       Apple Team ID
#                WHISPR_ASC_KEY_PATH   App Store Connect API key (.p8 file)
#                WHISPR_ASC_KEY_ID     ASC key id
#                WHISPR_ASC_ISSUER_ID  ASC issuer id
#
# Same audit story as macOS: the iOS binary contains no networking code. The
# only network activity in a release build is xcodebuild's own upload to App
# Store Connect — build tooling, not shipped code.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-check}"
PROJECT="$ROOT/ios/WhisprBro-iOS.xcodeproj"

command -v xcodegen >/dev/null 2>&1 || {
  echo "xcodegen not found — install it with: brew install xcodegen" >&2
  exit 1
}

if [[ "$MODE" == "release" ]]; then
  # Stage on-device models into the bundle before generating/archiving —
  # ios/Models is an optional folder reference in project.yml, so it ships as
  # a Models/ dir in the app's resources. English Parakeet v2 + Silero VAD
  # only; the multilingual v3 set stays a separate download, same as macOS.
  MODELS_SRC="${WHISPR_BRO_HOME:-$HOME/Library/Application Support/whispr-bro}/models"
  STAGE="$ROOT/ios/Models"
  rm -rf "$STAGE"
  if [[ -d "$MODELS_SRC/parakeet-tdt-0.6b-v2" && -d "$MODELS_SRC/silero-vad" ]]; then
    mkdir -p "$STAGE"
    cp -R "$MODELS_SRC/parakeet-tdt-0.6b-v2" "$STAGE/"
    cp -R "$MODELS_SRC/silero-vad" "$STAGE/"
    echo "bundling models: parakeet-tdt-0.6b-v2 + silero-vad"
  else
    echo "warning: models missing under $MODELS_SRC — archive ships without" \
      "bundled models (run scripts/fetch-models.sh first)" >&2
  fi
fi

# Braces are load-bearing: bash 3.2 (macOS /bin/bash) folds a following
# multibyte character into the variable name under `set -u`.
echo "generating ${PROJECT}…"
xcodegen generate --spec "$ROOT/ios/project.yml" --project "$ROOT/ios"

case "$MODE" in
  check)
    # CODE_SIGNING_ALLOWED=NO: catch compile/link errors on any machine
    # without an identity or provisioning profile. Pinned derivedDataPath so
    # the produced binary is findable for the symbol audit below.
    DDATA="$ROOT/.build/ios-ddata"
    xcodebuild -project "$PROJECT" -scheme WhisprBroiOS \
      -destination generic/platform=iOS \
      -derivedDataPath "$DDATA" \
      CODE_SIGNING_ALLOWED=NO \
      build
    # Tier 1/2 symbol audit of the iOS Mach-O (Tier 0 already scans all Swift
    # sources) — the zero-network guarantee is per-binary, not per-platform.
    IOS_BIN="$DDATA/Build/Products/Debug-iphoneos/WhisprBroiOS.app/WhisprBroiOS"
    if [[ -f "$IOS_BIN" ]]; then
      "$ROOT/scripts/audit-offline.sh" "$IOS_BIN"
    else
      echo "FAIL: iOS binary not found at $IOS_BIN for the offline audit" >&2
      exit 1
    fi
    echo "done: compile-check + iOS offline audit passed (unsigned, no bundle produced)"
    ;;
  release)
    : "${WHISPR_DEV_TEAM:?set WHISPR_DEV_TEAM to your Apple Team ID}"
    : "${WHISPR_ASC_KEY_PATH:?set WHISPR_ASC_KEY_PATH to the ASC API .p8 key path}"
    : "${WHISPR_ASC_KEY_ID:?set WHISPR_ASC_KEY_ID to the ASC key id}"
    : "${WHISPR_ASC_ISSUER_ID:?set WHISPR_ASC_ISSUER_ID to the ASC issuer id}"

    ARCHIVE="$ROOT/dist/WhisprBro-iOS.xcarchive"

    # -allowProvisioningUpdates + the ASC API key let xcodebuild create and
    # refresh profiles headlessly (CODE_SIGN_STYLE is Automatic in project.yml).
    xcodebuild -project "$PROJECT" -scheme WhisprBroiOS \
      -destination generic/platform=iOS \
      -archivePath "$ARCHIVE" \
      -allowProvisioningUpdates \
      -authenticationKeyPath "$WHISPR_ASC_KEY_PATH" \
      -authenticationKeyID "$WHISPR_ASC_KEY_ID" \
      -authenticationKeyIssuerID "$WHISPR_ASC_ISSUER_ID" \
      DEVELOPMENT_TEAM="$WHISPR_DEV_TEAM" \
      archive

    # TestFlight expiry is per-build: re-uploading an identical CFBundleVersion
    # does NOT restart the 90-day clock, so every archive gets a fresh,
    # monotonic build number:  <git commit count>.<UTC yyyymmddHHMMSS>
    # The first segment orders builds across commits; the timestamp breaks
    # ties when the same commit is archived twice, without any local state.
    # Stamped into the archived plists only (never the checked-in ones) — the
    # app + appex CFBundleVersions must match or ASC rejects the upload, and
    # the app-store-connect export re-signs, so post-archive edits are safe.
    BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD).$(date -u +%Y%m%d%H%M%S)"
    APP="$ARCHIVE/Products/Applications/WhisprBroiOS.app"
    STAMPED=0
    for PLIST in "$APP/Info.plist" "$APP"/PlugIns/*.appex/Info.plist; do
      [[ -f "$PLIST" ]] || continue
      /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"
      STAMPED=$((STAMPED + 1))
    done
    if [[ "$STAMPED" -lt 2 ]]; then
      echo "FAIL: expected app + keyboard Info.plists under $APP" >&2
      exit 1
    fi
    # Keep the archive's own metadata in sync (Organizer/export read it).
    /usr/libexec/PlistBuddy -c \
      "Set :ApplicationProperties:CFBundleVersion $BUILD_NUMBER" \
      "$ARCHIVE/Info.plist"
    echo "stamped CFBundleVersion $BUILD_NUMBER (app + keyboard + archive)"

    # ios/exportOptions.plist keeps a SET_ME teamID so no account details live
    # in git — stamp the real team into a throwaway copy for the export.
    EXPORT_OPTS="$ROOT/dist/exportOptions.plist"
    /usr/bin/sed "s/SET_ME/$WHISPR_DEV_TEAM/" "$ROOT/ios/exportOptions.plist" > "$EXPORT_OPTS"

    # method app-store-connect + destination upload → straight to TestFlight.
    xcodebuild -exportArchive \
      -archivePath "$ARCHIVE" \
      -exportOptionsPlist "$EXPORT_OPTS" \
      -exportPath "$ROOT/dist/ios-export" \
      -allowProvisioningUpdates \
      -authenticationKeyPath "$WHISPR_ASC_KEY_PATH" \
      -authenticationKeyID "$WHISPR_ASC_KEY_ID" \
      -authenticationKeyIssuerID "$WHISPR_ASC_ISSUER_ID"

    echo "done: uploaded to App Store Connect — watch TestFlight processing"
    ;;
  *)
    echo "usage: $0 [release]" >&2
    exit 2
    ;;
esac
