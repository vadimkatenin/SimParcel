#!/bin/bash
# Releases SimParcel: checks the prepared version, builds, signs with Developer ID, notarizes, packages a zip and
# a DMG, writes the Sparkle appcast, then (after you confirm) publishes a GitHub release and updates
# the Homebrew cask.
#
# One-time setup:
#   - A "Developer ID Application" certificate for the team in scripts/ExportOptions.plist.
#   - Notarization credentials in the keychain:
#       xcrun notarytool store-credentials "SimParcel" --apple-id "<Apple ID>" --team-id "D83JQSBRML"
#   - The Sparkle signing key in the keychain (created with `generate_keys --account SimParcel`).
#   - GitHub CLI signed in as the repository owner: gh auth login
#
# Usage: scripts/release.sh 1.1.0
#
# Merge the version change and release-notes/<version>.md into main through a PR first.
# Lines starting with "- " in the release notes become a list.

set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?Usage: scripts/release.sh <version>, for example 1.1.0}"
TAG="v$VERSION"
APP_NAME="SimParcel"
REPO="vadimkatenin/SimParcel"
TAP_REMOTE="git@github-personal:vadimkatenin/homebrew-tap.git"
NOTARY_PROFILE="${NOTARY_PROFILE:-SimParcel}"
SPARKLE_ACCOUNT="SimParcel"
NOTES="release-notes/$VERSION.md"
BUILD="build/release"
DERIVED_DATA="build/DerivedData"

step() {
    printf '\n\033[1m▸ %s\033[0m\n' "$1"
}

fail() {
    echo "error: $1" >&2
    exit 1
}

# MARK: - Checks

step "Checking the setup"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "The version must look like 1.2.3."
[[ -z $(git status --porcelain) ]] || fail "Commit or stash your changes first."
[[ $(git branch --show-current) == "main" ]] || fail "Release from the main branch."
[[ -f "$NOTES" ]] || fail "Write the release notes to $NOTES first."
PROJECT_VERSIONS=$(sed -nE 's/^[[:space:]]*MARKETING_VERSION = ([0-9.]+);/\1/p' SimParcel.xcodeproj/project.pbxproj | sort -u)
[[ "$PROJECT_VERSIONS" == "$VERSION" ]] \
    || fail "Set MARKETING_VERSION to $VERSION and merge it with $NOTES into main through a PR before releasing."
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    fail "Tag $TAG already exists."
fi
command -v gh >/dev/null || fail "Install the GitHub CLI: brew install gh"
[[ $(gh api user --jq .login 2>/dev/null) == "${REPO%%/*}" ]] || fail "Sign in to the GitHub CLI as ${REPO%%/*}: gh auth login"
git fetch origin main
[[ $(git rev-parse HEAD) == $(git rev-parse FETCH_HEAD) ]] \
    || fail "Local main must match origin/main. Merge the release preparation PR and update main before releasing."
[[ $(security find-identity -v -p codesigning) == *"Developer ID Application"* ]] \
    || fail "No Developer ID Application certificate. Create one in Xcode → Settings → Accounts → Manage Certificates."

# MARK: - Version

# Sparkle compares build numbers, so they must grow with every release. The commit count always does.
BUILD_NUMBER=$(git rev-list --count HEAD)
echo "Version $VERSION, build $BUILD_NUMBER"

# MARK: - Build

rm -rf "$BUILD"
mkdir -p "$BUILD"

step "Archiving"
xcodebuild archive \
    -project SimParcel.xcodeproj \
    -scheme SimParcel \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$DERIVED_DATA" \
    -archivePath "$BUILD/$APP_NAME.xcarchive" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    -quiet

step "Exporting with Developer ID"
xcodebuild -exportArchive \
    -archivePath "$BUILD/$APP_NAME.xcarchive" \
    -exportOptionsPlist scripts/ExportOptions.plist \
    -exportPath "$BUILD/export" \
    -quiet

APP="$BUILD/export/$APP_NAME.app"
codesign --verify --strict --deep "$APP"
# Read the signature into a variable: piping into `grep -q` would fail under pipefail when grep exits early.
SIGNATURE=$(codesign -dv --verbose=2 "$APP" 2>&1)
IDENTITY=$(awk -F= '/^Authority=Developer ID Application/ { print $2; exit }' <<< "$SIGNATURE")
[[ -n "$IDENTITY" ]] || fail "The exported app isn't signed with Developer ID."

step "Notarizing the app"
ditto -c -k --keepParent "$APP" "$BUILD/notarize.zip"
xcrun notarytool submit "$BUILD/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
rm "$BUILD/notarize.zip"

step "Packaging"
ZIP="$BUILD/$APP_NAME-$VERSION.zip"
DMG="$BUILD/$APP_NAME-$VERSION.dmg"
ditto -c -k --keepParent "$APP" "$ZIP"

STAGING="$BUILD/dmg"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG" -quiet
rm -rf "$STAGING"
codesign --sign "$IDENTITY" --timestamp "$DMG"

step "Notarizing the DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

step "Checking Gatekeeper"
xcrun stapler validate "$APP"
xcrun stapler validate "$DMG"
spctl --assess --type execute --verbose "$APP"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"

# MARK: - Appcast

step "Writing the Sparkle appcast"
SIGN_UPDATE="$DERIVED_DATA/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
[[ -x "$SIGN_UPDATE" ]] || fail "Sparkle's sign_update wasn't found at $SIGN_UPDATE."
# Prints: sparkle:edSignature="…" length="…"
ENCLOSURE_SIGNATURE=$("$SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" "$ZIP")
MINIMUM_SYSTEM=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist")

python3 - "$NOTES" "$BUILD/release-notes.html" <<'PYTHON'
import html, sys

lines = open(sys.argv[1]).read().splitlines()
parts, in_list = [], False
for line in lines:
    text = line.strip()
    if text.startswith("- "):
        if not in_list:
            parts.append("<ul>")
            in_list = True
        parts.append(f"<li>{html.escape(text[2:])}</li>")
        continue
    if in_list:
        parts.append("</ul>")
        in_list = False
    if text.startswith("#"):
        parts.append(f"<h3>{html.escape(text.lstrip('#').strip())}</h3>")
    elif text:
        parts.append(f"<p>{html.escape(text)}</p>")
if in_list:
    parts.append("</ul>")
open(sys.argv[2], "w").write("\n".join(parts))
PYTHON

cat > "$BUILD/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>$APP_NAME</title>
        <link>https://github.com/$REPO</link>
        <item>
            <title>$APP_NAME $VERSION</title>
            <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
            <sparkle:version>$BUILD_NUMBER</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>$MINIMUM_SYSTEM</sparkle:minimumSystemVersion>
            <sparkle:fullReleaseNotesLink>https://github.com/$REPO/releases/tag/$TAG</sparkle:fullReleaseNotesLink>
            <description><![CDATA[
$(cat "$BUILD/release-notes.html")
            ]]></description>
            <enclosure url="https://github.com/$REPO/releases/download/$TAG/$(basename "$ZIP")" type="application/octet-stream" $ENCLOSURE_SIGNATURE />
        </item>
    </channel>
</rss>
XML
xmllint --noout "$BUILD/appcast.xml"

ZIP_SHA=$(shasum -a 256 "$ZIP" | awk '{ print $1 }')
DMG_SHA=$(shasum -a 256 "$DMG" | awk '{ print $1 }')

# MARK: - Publish

step "Ready to publish $APP_NAME $VERSION (build $BUILD_NUMBER)"
echo "  $ZIP  $ZIP_SHA"
echo "  $DMG  $DMG_SHA"
echo "  $BUILD/appcast.xml"
read -r -p "Push $TAG, create the GitHub release and update the Homebrew cask? [y/N] " answer
if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
    echo "Stopped before publishing. The build is in $BUILD."
    exit 0
fi

step "Publishing the GitHub release"
git tag -a "$TAG" -m "$APP_NAME $VERSION"
git push origin "$TAG"

{
    cat "$NOTES"
    printf '\n### Checksums\n\n```\n%s  %s\n%s  %s\n```\n' "$ZIP_SHA" "$(basename "$ZIP")" "$DMG_SHA" "$(basename "$DMG")"
} > "$BUILD/github-notes.md"

# An unversioned copy lets https://katenin.dev/simparcel link to releases/latest/download/SimParcel.dmg.
cp "$DMG" "$BUILD/$APP_NAME.dmg"

gh release create "$TAG" "$DMG" "$ZIP" "$BUILD/$APP_NAME.dmg" "$BUILD/appcast.xml" \
    --repo "$REPO" \
    --title "$APP_NAME $VERSION" \
    --notes-file "$BUILD/github-notes.md"

step "Updating the Homebrew cask"
TAP="$BUILD/homebrew-tap"
git clone -q "$TAP_REMOTE" "$TAP"
# Commit to the tap with this repository's identity, not the global one.
git -C "$TAP" config user.name "$(git config user.name)"
git -C "$TAP" config user.email "$(git config user.email)"
mkdir -p "$TAP/Casks"
cat > "$TAP/Casks/simparcel.rb" <<RUBY
cask "simparcel" do
  version "$VERSION"
  sha256 "$ZIP_SHA"

  url "https://github.com/$REPO/releases/download/v#{version}/$APP_NAME-#{version}.zip"
  name "$APP_NAME"
  desc "Drag and drop media, apps and push payloads into iOS Simulators"
  homepage "https://github.com/$REPO"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: :sonoma

  app "$APP_NAME.app"

  zap trash: [
    "~/Library/Caches/com.vadimkatenin.SimParcel",
    "~/Library/HTTPStorages/com.vadimkatenin.SimParcel",
    "~/Library/Preferences/com.vadimkatenin.SimParcel.plist",
  ]
end
RUBY
git -C "$TAP" add Casks/simparcel.rb
git -C "$TAP" commit -q -m "simparcel $VERSION"
git -C "$TAP" push -q origin HEAD

step "Released $APP_NAME $VERSION"
echo "https://github.com/$REPO/releases/tag/$TAG"
echo "brew install --cask vadimkatenin/tap/simparcel"
