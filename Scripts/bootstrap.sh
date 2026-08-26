#!/usr/bin/env bash
# Generates Searchister.xcodeproj from project.yml.
#
# The project file is not committed: it is a generated artifact, and hand-merging pbxproj
# conflicts is worse than regenerating.
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "xcodegen is required. Install it with:  brew install xcodegen" >&2
    exit 1
fi

xcodegen generate
echo "Generated Searchister.xcodeproj"
echo
echo "Next steps:"
echo "  1. Create Scripts/Local.xcconfig with:  DEVELOPMENT_TEAM = YOURTEAMID"
echo "  2. Register the App Group 'group.app.clutchlabs.searchister' in your developer account"
echo "  3. open Searchister.xcodeproj"
