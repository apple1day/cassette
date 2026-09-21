#!/usr/bin/env bash
# Portable tests of the exact app core sources; no signing, server or media access.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
command -v swift >/dev/null || { echo 'Swift 6.2+ is required (Xcode 26+ on Mac).' >&2; exit 1; }
work="$(mktemp -d "${TMPDIR:-/tmp}/cassette-signing.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/CassetteSigningCore" "$work/Tests/CassetteSigningCoreTests"
cp "$root/Cassette/Features/Signing/SigningStatus.swift" "$root/Cassette/Features/Signing/SigningReminder.swift" "$work/Sources/CassetteSigningCore/"
cp "$root/CassetteTests/SigningExpiryTests.swift" "$work/Tests/CassetteSigningCoreTests/"
cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "CassetteSigningCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "CassetteSigningCore", targets: ["CassetteSigningCore"])],
    targets: [
        .target(name: "CassetteSigningCore"),
        .testTarget(name: "CassetteSigningCoreTests", dependencies: ["CassetteSigningCore"])
    ],
    swiftLanguageModes: [.v5]
)
SWIFT
swift --version
swift test --package-path "$work"
# Match Cassette's default isolation and check complete concurrency, not just parsing.
swiftc -swift-version 5 -default-isolation MainActor -strict-concurrency=complete \
    -enable-upcoming-feature NonisolatedNonsendingByDefault \
    -enable-upcoming-feature InferIsolatedConformances \
    -enable-upcoming-feature MemberImportVisibility \
    -warnings-as-errors -typecheck "$work"/Sources/CassetteSigningCore/*.swift
echo 'PASS: core typechecks with Cassette MainActor / approachable-concurrency settings.'
