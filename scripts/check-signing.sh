#!/usr/bin/env bash
# Isolated, offline core tests. Does not read a real profile or touch music data.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/cassette-signing.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/CassetteSigningCore" "$work/Tests/CassetteSigningCoreTests"
cp "$root/Cassette/Services/Signing/SigningStatus.swift" "$root/Cassette/Services/Signing/SigningReminder.swift" "$work/Sources/CassetteSigningCore/"
cp "$root/CassetteTests/SigningExpiryTests.swift" "$work/Tests/CassetteSigningCoreTests/"
cat > "$work/Package.swift" <<'PACKAGE'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "CassetteSigningCore", platforms: [.macOS(.v15)], targets: [
    .target(name: "CassetteSigningCore", swiftSettings: [
        .unsafeFlags(["-default-isolation", "MainActor", "-warnings-as-errors"]),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
        .enableUpcomingFeature("InferIsolatedConformances"),
        .enableUpcomingFeature("MemberImportVisibility")
    ]),
    .testTarget(name: "CassetteSigningCoreTests", dependencies: ["CassetteSigningCore"])
], swiftLanguageModes: [.v5])
PACKAGE
swift test --package-path "$work" --jobs 2
