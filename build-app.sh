#!/bin/zsh
# Builds a self-contained "Talk to Dad.app" (system frameworks only) into ./dist.
set -e
cd "${0:A:h}"
VERSION=$(cat VERSION)
# Stable signing identity so macOS keeps Dad's permissions across updates.
SIGN_ID="${TTD_SIGN_ID:-Apple Development: Iles Wade (W7Q4ZU9D65)}"
swift build -c release
APP="dist/Talk to Dad.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/TalkToDad "$APP/Contents/MacOS/TalkToDad"
cp -R .build/release/FluidAudio_FluidAudio.bundle "$APP/Contents/Resources/"
# Bundle the Kokoro voice models so Dad's Mac never downloads anything.
# They come from a first run on this Mac (~/Library/Application Support/Talk to Dad/Models).
MODELS="$HOME/Library/Application Support/Talk to Dad/Models"
G2P="$HOME/.cache/fluidaudio/Models/kokoro"
mkdir -p "$APP/Contents/Resources/KokoroG2P"
for f in G2PEncoder.mlmodelc G2PDecoder.mlmodelc g2p_vocab.json config.json us_lexicon_cache.json us_gold.json us_silver.json gb_gold.json gb_silver.json; do
  [ -e "$G2P/$f" ] && cp -R "$G2P/$f" "$APP/Contents/Resources/KokoroG2P/"
done
if [ -d "$MODELS" ]; then cp -R "$MODELS" "$APP/Contents/Resources/Models"; else echo "warning: no Kokoro models yet; run the app once, then rebuild"; fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.ris.talktodad</string>
  <key>CFBundleName</key><string>Talk to Dad</string>
  <key>CFBundleDisplayName</key><string>Talk to Dad</string>
  <key>CFBundleExecutable</key><string>TalkToDad</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Talk to Dad listens for Dad's spoken answer after reading a message aloud.</string>
  <key>NSCameraUsageDescription</key><string>Talk to Dad takes a photo when Iles or Nicole checks in from the family app.</string>
  <key>NSAppleEventsUsageDescription</key><string>Talk to Dad sends Dad's spoken answers back by iMessage when that's switched on.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Talk to Dad turns Dad's spoken answer into text on this Mac.</string>
</dict></plist>
PLIST
codesign --force --deep --sign "$SIGN_ID" "$APP"
ditto -c -k --keepParent "$APP" dist/Talk-to-Dad.zip
# Drag-to-install disk image for a fresh Mac.
STAGE=$(mktemp -d); cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
rm -f dist/Talk-to-Dad.dmg
hdiutil create -quiet -volname "Talk to Dad" -srcfolder "$STAGE" -format UDZO dist/Talk-to-Dad.dmg
rm -rf "$STAGE"
echo "built $APP ($(du -sh "$APP" | cut -f1))"

# Family app (Iles's and Nicole's Macs): small, no voice models.
FAM="dist/TTD Family.app"
rm -rf "$FAM"; mkdir -p "$FAM/Contents/MacOS" "$FAM/Contents/Resources"
cp .build/release/TTDFamily "$FAM/Contents/MacOS/TTDFamily"
cat > "$FAM/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.ris.ttdfamily</string>
  <key>CFBundleName</key><string>TTD Family</string>
  <key>CFBundleDisplayName</key><string>TTD Family</string>
  <key>CFBundleExecutable</key><string>TTDFamily</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
</dict></plist>
PLIST
codesign --force --sign "$SIGN_ID" "$FAM"
ditto -c -k --keepParent "$FAM" dist/TTD-Family.zip
echo "built $FAM ($(du -sh "$FAM" | cut -f1))"
