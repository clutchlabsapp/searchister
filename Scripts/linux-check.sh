#!/usr/bin/env bash
#
# Compile and test the portable part of HisterKit on Linux, where there is no Xcode.
#
# The package targets Apple platforms, so six files cannot build here: KeychainStore (Security),
# SpotlightIndexer (CoreSpotlight), DocumentExtractor (UIKit), PageFetcher (CoreFoundation charset
# APIs), OutboxUploader (background URLSession) and IngestService, which depends on those. Everything
# else — the client, the local index, sync and search, where nearly all the logic lives — builds,
# and its tests run.
#
# Sources are copied into a scratch package and patched there; the repo keeps Apple-shaped imports
# and never sees a Linux-only edit. KeychainStore and AppGroup are replaced by stubs under
# Scripts/LinuxCheck/Stubs with the same public signatures, so everything downstream typechecks
# against the API it will meet on a Mac.
#
# This is a fast correctness check, not a substitute for building the app: nothing in Apps/ is
# SwiftUI-checkable here, and neither are the six files above.
#
# Usage: Scripts/linux-check.sh [build|test] [extra swift arguments...]
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$REPO/Scripts/LinuxCheck"

if ! command -v swift >/dev/null 2>&1; then
    if [ -x /opt/swift/usr/bin/swift ]; then
        export PATH=/opt/swift/usr/bin:$PATH
    else
        echo "swift not found on PATH. Install a Linux toolchain from https://swift.org/download/" >&2
        exit 127
    fi
fi

rm -rf "$WORK/Sources" "$WORK/Tests"
mkdir -p "$WORK/Sources" "$WORK/Tests"
cp -r "$REPO/HisterKit/Sources/HisterKit" "$WORK/Sources/HisterKit"
cp -r "$REPO/HisterKit/Tests/HisterKitTests" "$WORK/Tests/HisterKitTests"

rm -f "$WORK/Sources/HisterKit/Client/KeychainStore.swift" \
      "$WORK/Sources/HisterKit/Spotlight/SpotlightIndexer.swift" \
      "$WORK/Sources/HisterKit/Ingest/DocumentExtractor.swift" \
      "$WORK/Sources/HisterKit/Ingest/IngestService.swift" \
      "$WORK/Sources/HisterKit/Ingest/PageFetcher.swift" \
      "$WORK/Sources/HisterKit/Sync/OutboxUploader.swift" \
      "$WORK/Sources/HisterKit/Support/AppGroup.swift"
rm -f "$WORK/Tests/HisterKitTests/SpotlightIndexerTests.swift" \
      "$WORK/Tests/HisterKitTests/IngestTests.swift"
cp "$WORK/Stubs/KeychainStore.swift" "$WORK/Sources/HisterKit/Client/KeychainStore.swift"
cp "$WORK/Stubs/AppGroup.swift" "$WORK/Sources/HisterKit/Support/AppGroup.swift"

# URLRequest, URLSession and XMLParser come with Foundation on Apple platforms and live in
# FoundationNetworking / FoundationXML on Linux.
find "$WORK/Sources" "$WORK/Tests" -name '*.swift' -print0 | while IFS= read -r -d '' file; do
    grep -q '^import Foundation$' "$file" || continue
    sed -i '0,/^import Foundation$/s//import Foundation\n#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif\n#if canImport(FoundationXML)\nimport FoundationXML\n#endif/' "$file"
done

cd "$WORK"
exec swift "${1:-test}" "${@:2}"
