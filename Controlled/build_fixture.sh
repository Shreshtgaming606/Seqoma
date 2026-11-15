#!/bin/zsh
set -euo pipefail
script_dir=${0:A:h}
output_dir=${1:-"${script_dir}/build"}
mkdir -p "$output_dir/ControlledApp.app/Contents/MacOS"
sdk=$(/usr/bin/xcrun --sdk macosx --show-sdk-path)
/usr/bin/xcrun swiftc -parse-as-library -target x86_64-apple-macosx15.0 -sdk "$sdk" -DSEQOMA_STUB -framework SwiftUI -framework AppKit -o "$output_dir/ControlledApp.app/Contents/MacOS/ControlledApp" "$script_dir/ControlledApp.swift"
cat > "$output_dir/ControlledApp.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ControlledApp</string>
<key>CFBundleIdentifier</key><string>dev.seqoma.controlled</string>
<key>CFBundleName</key><string>ControlledApp</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - "$output_dir/ControlledApp.app"
print "$output_dir/ControlledApp.app"
