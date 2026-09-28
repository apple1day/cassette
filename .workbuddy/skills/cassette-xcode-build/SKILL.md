---
name: cassette-xcode-build
description: Build and validate the Cassette Swift/Xcode project in this workspace. Use when asked to compile Cassette, verify Swift changes, run xcodebuild, or fix Cassette build errors.
agent_created: true
---

# Cassette Xcode Build

## Overview

This skill documents how to compile and validate the Cassette SwiftUI app from the command line in this environment, plus one recurring Swift concurrency gotcha that has already bitten the project once.

## Build command

Use this exact invocation. The `DEVELOPER_DIR` prefix avoids relying on the system `xcode-select`; `-disableAutomaticPackageResolution` prevents xcodebuild from re-spawning the sandboxed SPM resolver, which is blocked in this environment; the explicit iOS Simulator destination avoids falling back to the macOS target, which currently fails on `SongsListView.swift` because `.insetGrouped` is unavailable on macOS.

```bash
cd /Users/even/mine/anxiong/cassette && \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -scheme Cassette \
           -configuration Debug \
           -destination 'platform=iOS Simulator,name=iPhone 17' \
           -disableAutomaticPackageResolution \
           build
```

For a quieter summary:

```bash
... build -quiet 2>&1 | tail -30
```

A successful build ends with `** BUILD SUCCEEDED **`.

## What NOT to do

- Do not rely on bare `xcodebuild` or `swift build`; bare invocations usually hit the `sandbox-exec: sandbox_apply: Operation not permitted` error during package resolution.
- Do not omit `-destination`; the default `My Mac` destination surfaces the unrelated `SongsListView.swift:158` `.insetGrouped` macOS error.
- Do not assume the Command Line Tools toolchain is enough; point `DEVELOPER_DIR` to `/Applications/Xcode.app/Contents/Developer`.

## Swift concurrency gotcha: `MainActor.run` inside `if`/`guard`

Inside an `if` or `guard`, `await MainActor.run { ... }` cannot use trailing-closure syntax, so `await MainActor.run({ ... })` is tempting. That compiles the closure into the `resultType:` parameter position and produces diagnostics like:

- Missing argument label 'resultType:' in call
- Closure passed to parameter of type 'Bool.Type' that does not accept a closure
- Missing argument for parameter 'body' in call

Fix: always pass the `body:` label explicitly when trailing-closure syntax is unavailable:

```swift
// Wrong
if await MainActor.run({ state.isShuffled }) { ... }

// Right
if await MainActor.run(body: { state.isShuffled }) { ... }
```

## Common follow-up checks after Swift changes

1. If a protocol gained a new requirement (e.g. `PlayerServiceProtocol.setPlaybackMode`), update any mock conformers in `CassetteTests/`.
2. This project uses `PBXFileSystemSynchronizedRootGroup` folder references; new `.swift` files under `Cassette/` are picked up automatically without editing `project.pbxproj`.
3. New optional `@Model` properties (e.g. on `PlaybackSession`) rely on SwiftData lightweight migration; if schema errors appear on first launch, delete the in-memory/session store during development.
