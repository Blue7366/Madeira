#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="${PROJECT_PATH:-$REPO_ROOT/app/Madeira.xcodeproj}"
SCHEME="${SCHEME:-Madeira}"
CONFIGURATION="${CONFIGURATION:-Release}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$REPO_ROOT/build/Madeira.xcarchive}"
EXPORT_PATH="${EXPORT_PATH:-$REPO_ROOT/build/ipa}"
METHOD="${METHOD:-development}"
TEAM_ID="${TEAM_ID:-}"
EXPORT_OPTIONS_PATH="${EXPORT_OPTIONS_PATH:-$REPO_ROOT/scripts/ExportOptions.plist}"

if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "xcodebuild was not found. Run this on macOS with Xcode installed." >&2
    exit 1
fi

if [ ! -d "$PROJECT_PATH" ]; then
    echo "Project not found at $PROJECT_PATH" >&2
    exit 1
fi

mkdir -p "$(dirname "$ARCHIVE_PATH")" "$EXPORT_PATH"

cat > "$EXPORT_OPTIONS_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>compileBitcode</key>
    <false/>
    <key>destination</key>
    <string>export</string>
    <key>method</key>
    <string>${METHOD}</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>stripSwiftSymbols</key>
    <true/>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>uploadSymbols</key>
    <false/>
</dict>
</plist>
EOF

if [ -n "$TEAM_ID" ]; then
    echo "Packaging Madeira with team ID $TEAM_ID"
else
    echo "Packaging Madeira with automatic signing"
fi

echo "Archiving $SCHEME ..."
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  archive

echo "Exporting IPA ..."
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PATH" \
  -exportPath "$EXPORT_PATH" \
  -allowProvisioningUpdates

IPA_PATH=$(find "$EXPORT_PATH" -maxdepth 1 -name '*.ipa' | head -n 1)
if [ -n "$IPA_PATH" ]; then
    echo "IPA ready at: $IPA_PATH"
else
    echo "No .ipa was produced in $EXPORT_PATH" >&2
    exit 1
fi
