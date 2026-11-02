#!/bin/zsh
# eGlu for Mac as a disk image to download: signed with Developer ID,
# with the hardened runtime, notarised by Apple and stapled, so it opens on
# any Mac without Gatekeeper's warning. It is the only way to the Mac app,
# which is not on the Mac App Store.
#
#   Release/mac.sh             build, sign and pack: build/mac/eGlu-<version>.<build>.dmg
#   Release/mac.sh notarize    the same, then the app and the disk image notarised and stapled
#   Release/mac.sh release     the same, after checking it can be released, then the
#                              disk image signed for Sparkle and the appcast with it:
#                              build/mac/appcast.xml, and a summary. Nothing is published.
#   Release/mac.sh release --publish
#                              the same, then a GitHub release v<version> on
#                              eGlu-dot-app/eGlu with the disk image and the
#                              appcast, marked latest: installed copies find it there
#                              (SUFeedURL, .../releases/latest/download/appcast.xml)
#
# The app is the eGlu Mac Direct target: eGlu Mac with Sparkle 2,
# which updates it (Mac/Sources/Updates.swift).
#
# Needs:
#   - the "Developer ID Application" certificate, with its private key, in the
#     keychain; the team is read from it (or DEVELOPMENT_TEAM)
#   - to notarise: eGlu's notary sign-in, in a file named for the app and
#     kept out of the repository, as Harper's is (SAFIENCE_NOTARY_ENV, by
#     default ~/.appstoreconnect/safience-notary.env), which sets
#     ASC_KEY_PATH to an App Store Connect API key's .p8, ASC_KEY_ID and
#     ASC_ISSUER_ID; or a notarytool keychain profile (NOTARY_PROFILE, made
#     once with `xcrun notarytool store-credentials safience`). Notarising
#     sends the app to Apple, who look it over and keep a ticket.
#   - ICLOUD=1 for a build with iCloud sync, signed with its production
#     entitlements (Config/eGluMacRelease.entitlements) and the team's
#     Developer ID provisioning profile, which Release/profile.py makes in the
#     team's account and installs, once (PROFILE names another). A Developer
#     ID profile names no devices: nothing else in the account changes.
#     Without ICLOUD the build has everything but sync, which Settings ›
#     iCloud then says it isn't signed for.
#
#   - to release: Sparkle's EdDSA key in the login keychain, account
#     "safience" (made once with Sparkle's generate_keys --account safience;
#     its public half is SPARKLE_PUBLIC_KEY in project.yml), a clean working
#     tree, CURRENT_PROJECT_VERSION higher than the newest build in the
#     published appcast, and a "## <version>" section in CHANGELOG.md; and
#     to publish, gh signed in. Sparkle's tools come into build/ once, from
#     its GitHub release, checked against GitHub's digest.
#
# The disk image's window is laid out by Release/dmg.py through dmgbuild,
# installed into build/ the first time (Python 3), as the Mac's Search lays
# out its own (its Installer/dmg.py); without it, a plain disk image.
set -euo pipefail
cd "$(dirname "$0")/.."

STEP="${1:-pack}"
PUBLISH="${2:-}"
OUT="build/mac"
NAME="eGlu"
NOTARIZE=""
[[ "$STEP" == "notarize" || "$STEP" == "release" ]] && NOTARIZE=1
REPO="eGlu-dot-app/eGlu"
FEED="https://github.com/$REPO/releases/latest/download/appcast.xml"
SPARKLE_VERSION="2.10.0"
SPARKLE="build/sparkle-$SPARKLE_VERSION"

# The notary service's sign-in, from the app's own file, unless already set.
NOTARY_ENV="${SAFIENCE_NOTARY_ENV:-$HOME/.appstoreconnect/safience-notary.env}"
if [[ -z "${ASC_KEY_PATH:-}${NOTARY_PROFILE:-}" && -f "$NOTARY_ENV" ]]; then
  source "$NOTARY_ENV"
fi

# The Developer ID identity, and its team: "Developer ID Application: Name (TEAM)".
IDENTITY_LINE="$(security find-identity -v -p codesigning | grep '"Developer ID Application:' | head -1 || true)"
if [[ -z "$IDENTITY_LINE" ]]; then
  echo "No Developer ID Application certificate in the keychain: Xcode › Settings › Accounts › Manage Certificates." >&2
  exit 1
fi
IDENTITY="$(echo "$IDENTITY_LINE" | awk '{print $2}')"
TEAM="${DEVELOPMENT_TEAM:-$(echo "$IDENTITY_LINE" | sed -E 's/.*\(([A-Z0-9]+)\)".*/\1/')}"

# How notarytool signs in: a keychain profile, or the API key.
NOTARY=()
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  NOTARY=(--keychain-profile "$NOTARY_PROFILE")
  [[ -n "${NOTARY_KEYCHAIN:-}" ]] && NOTARY+=(--keychain "$NOTARY_KEYCHAIN")
elif [[ -n "${ASC_KEY_PATH:-}" && -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]]; then
  NOTARY=(--key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
fi
if [[ -n "$NOTARIZE" && ${#NOTARY} -eq 0 ]]; then
  echo "To notarise: $NOTARY_ENV with ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID, or NOTARY_PROFILE." >&2
  exit 1
fi

# Signed by hand with Developer ID; with iCloud, with the provisioning
# profile iCloud's entitlements need too.
SIGNING=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=Developer ID Application" "DEVELOPMENT_TEAM=$TEAM")
PROFILES=""
if [[ -n "${ICLOUD:-}" ]]; then
  ENTITLEMENTS="Config/eGluMacRelease.entitlements"
  PROFILE="${PROFILE:-Safience Developer ID}"
  # The app's alone (MAC_PROFILE, Config/Mac.xcconfig): PadCore's resource bundle takes none.
  SIGNING+=("MAC_PROFILE=$PROFILE")
  BUNDLE="$(grep -E '^PRODUCT_BUNDLE_IDENTIFIER' Config/Signing.xcconfig | sed -E 's/.*= *//')"
  PROFILES="<key>provisioningProfiles</key><dict><key>$BUNDLE</key><string>$PROFILE</string></dict>"
else
  ENTITLEMENTS="Config/eGluMacDirect.entitlements"
fi

# What a release needs before anything is built: Sparkle's tools, a clean
# tree (the release is what is committed), a build newer than the newest
# already offered, and the key to sign it with.
if [[ "$STEP" == "release" ]]; then
  if [[ ! -x "$SPARKLE/bin/sign_update" ]]; then
    echo "Fetching Sparkle $SPARKLE_VERSION's tools…"
    mkdir -p "$SPARKLE"
    gh release download "$SPARKLE_VERSION" --repo sparkle-project/Sparkle --pattern "Sparkle-$SPARKLE_VERSION.tar.xz" --dir "$SPARKLE" --clobber
    DIGEST="$(gh api "repos/sparkle-project/Sparkle/releases/tags/$SPARKLE_VERSION" --jq ".assets[] | select(.name == \"Sparkle-$SPARKLE_VERSION.tar.xz\") | .digest")"
    [[ "$DIGEST" == "sha256:$(shasum -a 256 "$SPARKLE/Sparkle-$SPARKLE_VERSION.tar.xz" | awk '{print $1}')" ]] \
      || { echo "Sparkle's tools don't match GitHub's digest." >&2; exit 1; }
    tar -xf "$SPARKLE/Sparkle-$SPARKLE_VERSION.tar.xz" -C "$SPARKLE"
  fi
  [[ -z "$(git status --porcelain)" ]] || { echo "Commit or set aside what has changed first: a release is what is committed." >&2; exit 1; }
  "$SPARKLE/bin/generate_keys" --account safience -p >/dev/null 2>&1 \
    || { echo "No Sparkle key in the keychain (account safience): $SPARKLE/bin/generate_keys --account safience, or -f to import the backup." >&2; exit 1; }
  BUILD_NEXT="$(grep -E '^ *CURRENT_PROJECT_VERSION:' project.yml | sed -E 's/[^0-9]//g')"
  PREVIOUS="$OUT-previous-appcast.xml"
  rm -f "$PREVIOUS"
  if curl -fsSL "$FEED" -o "$PREVIOUS" 2>/dev/null; then
    NEWEST="$(python3 Release/appcast.py --newest "$PREVIOUS")"
    if [[ -n "$NEWEST" && "$BUILD_NEXT" -le "$NEWEST" ]]; then
      echo "Build $BUILD_NEXT is not newer than $NEWEST, the newest offered: raise CURRENT_PROJECT_VERSION in project.yml." >&2
      exit 1
    fi
  else
    rm -f "$PREVIOUS"
    echo "No appcast published yet: this is the first."
  fi
fi

rm -rf "$OUT"
mkdir -p "$OUT"

echo "Archiving $NAME (Release, signed with Developer ID, $([[ -n "${ICLOUD:-}" ]] && echo "with iCloud" || echo "without iCloud"))…"
xcodebuild archive -quiet \
  -project eGlu.xcodeproj -scheme "eGlu Mac Direct" -configuration Release \
  -destination "generic/platform=macOS" -archivePath "$OUT/$NAME.xcarchive" -packageAuthorizationProvider netrc \
  "MAC_ENTITLEMENTS=$ENTITLEMENTS" ENABLE_HARDENED_RUNTIME=YES "${SIGNING[@]}"

# Exported for Developer ID: signed again with a secure timestamp, which notarisation asks for.
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
  $PROFILES
</dict>
</plist>
PLIST
echo "Exporting for Developer ID…"
xcodebuild -exportArchive -quiet -archivePath "$OUT/$NAME.xcarchive" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$OUT/export"
APP="$OUT/export/$NAME.app"
codesign --verify --deep --strict "$APP"
SIGNATURE="$(codesign --display --verbose=4 "$APP" 2>&1)"
[[ "$SIGNATURE" == *"(runtime)"* && "$SIGNATURE" == *"Timestamp="* ]] \
  || { echo "The app isn't signed with the hardened runtime and a timestamp, which notarisation asks for." >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")"
DMG="$OUT/$NAME-$VERSION.$BUILD.dmg"

# Sent to Apple and waited for; the ticket stapled to `file` on acceptance,
# and Apple's log printed on anything else.
# (`verdict`, not `status`: zsh keeps `status` for the last exit code.)
notarize() {
  local file="$1" result id verdict
  echo "Notarising $(basename "$file")…"
  # A refusal is answered below, with Apple's log, rather than by set -e.
  result="$(xcrun notarytool submit "$file" "${NOTARY[@]}" --wait --output-format json || true)"
  id="$(echo "$result" | python3 -c 'import json, sys; print(json.load(sys.stdin).get("id", ""))' 2>/dev/null || true)"
  verdict="$(echo "$result" | python3 -c 'import json, sys; print(json.load(sys.stdin).get("status", ""))' 2>/dev/null || true)"
  if [[ "$verdict" != "Accepted" ]]; then
    echo "Notarisation: ${verdict:-no answer} $result" >&2
    [[ -n "$id" ]] && xcrun notarytool log "$id" "${NOTARY[@]}" >&2
    exit 1
  fi
}

# The app first, so that it opens without asking even taken out of the disk
# image and opened with no network to check it by.
if [[ -n "$NOTARIZE" ]]; then
  ditto -c -k --keepParent "$APP" "$OUT/$NAME.zip"
  notarize "$OUT/$NAME.zip"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  rm "$OUT/$NAME.zip"
fi

echo "Packing $(basename "$DMG")…"
DMGBUILD="build/dmgbuild/bin/dmgbuild"
if [[ ! -x "$DMGBUILD" ]]; then
  { python3 -m venv build/dmgbuild && build/dmgbuild/bin/pip install --quiet "dmgbuild==1.6.7"; } >/dev/null 2>&1 || true
fi
if [[ -x "$DMGBUILD" ]]; then
  "$DMGBUILD" -s Release/dmg.py -D "app=$APP" "$NAME" "$DMG" >/dev/null
else
  echo "note: no dmgbuild, a plain disk image without its window laid out" >&2
  STAGE="$OUT/dmg"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
  rm -rf "$STAGE"
fi
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [[ -n "$NOTARIZE" ]]; then
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  # What a Mac that downloads it decides: the disk image, and the app in it.
  spctl --assess --type open --context context:primary-signature --verbose "$DMG"
  spctl --assess --type execute --verbose "$APP"
fi

echo "Done: $DMG ($VERSION.$BUILD)$([[ -n "$NOTARIZE" ]] && echo ", notarised and stapled")"

# The disk image signed for Sparkle, and the appcast with it at its top.
if [[ "$STEP" == "release" ]]; then
  SIGNED="$("$SPARKLE/bin/sign_update" --account safience "$DMG")"
  SIGNATURE="$(echo "$SIGNED" | sed -E 's/.*sparkle:edSignature="([^"]+)".*/\1/')"
  LENGTH="$(stat -f %z "$DMG")"
  URL="https://github.com/$REPO/releases/download/v$VERSION/$(basename "$DMG")"
  FROM=()
  [[ -f "$PREVIOUS" ]] && FROM=(--previous "$PREVIOUS")
  python3 Release/appcast.py "${FROM[@]}" --out "$OUT/appcast.xml" \
    --version "$VERSION" --build "$BUILD" --url "$URL" --length "$LENGTH" --signature "$SIGNATURE" --notes CHANGELOG.md
  echo
  echo "Ready to release eGlu $VERSION (build $BUILD):"
  echo "  $DMG ($LENGTH bytes), signed for Sparkle"
  echo "  $OUT/appcast.xml, for $URL"
  if [[ "$PUBLISH" == "--publish" ]]; then
    # The section the appcast's notes come from (appcast.py): the version's, else Unreleased's.
    awk -v v="$VERSION" '/^## /{p = ($2 == v)} p' CHANGELOG.md > "$OUT/notes.md"
    [[ -s "$OUT/notes.md" ]] || awk '/^## /{p = ($2 == "Unreleased")} p' CHANGELOG.md > "$OUT/notes.md"
    [[ -s "$OUT/notes.md" ]] || echo "eGlu $VERSION" > "$OUT/notes.md"
    gh release create "v$VERSION" --repo "$REPO" --title "eGlu $VERSION" --notes-file "$OUT/notes.md" --latest \
      "$DMG" "$OUT/appcast.xml"
    echo "Published: https://github.com/$REPO/releases/tag/v$VERSION"
  else
    echo "Nothing is published. To publish: Release/mac.sh release --publish"
  fi
fi
