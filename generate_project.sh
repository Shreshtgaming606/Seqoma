#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
command -v xcodegen >/dev/null || { print -u2 "Install XcodeGen 2.46 or newer first"; exit 1; }
xcodegen generate
# XcodeGen 2.46 defaults to a project object version newer than Xcode 15.4.
sed -i '' 's/objectVersion = 77;/objectVersion = 60;/; s/preferredProjectObjectVersion = 77;/preferredProjectObjectVersion = 60;/' Seqoma.xcodeproj/project.pbxproj
