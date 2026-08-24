// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// SwiftPM manifest for the pure-logic half of ArcSeven.
//
// Only the two AppKit-free modules live here:
//
//   ArchiveCore  the engine layer - ArchiveEngine protocol, the 7zz subprocess driver,
//                the `l -slt` parser, the backspace-aware stream tokenizer, exit-code
//                mapping, the format catalogue, the memory estimator.
//   FMKit        the file-manager domain - FolderProvider and its implementations, the
//                panel model, the sort comparator, the column model, the persistence
//                stores. Models and logic only; not a single view.
//
// Both are deliberately free of AppKit so `swift build` / `swift test` run on a bare
// checkout with no Xcode project, no code signing, and no vendored 7zz. That is what
// .github/workflows/ci.yml exercises on every push and pull request, including pull
// requests from forks, which never see repository secrets.
//
// The AppKit modules (FMUI, Dialogs, SettingsUI, Support, App) and the two app
// extensions are built by the Xcode project generated from project.yml, which compiles
// Sources/ArchiveCore and Sources/FMKit directly rather than depending on this package.
// Keeping both build systems pointed at the same directories means there is exactly one
// copy of every source file.
//
// NO EXTERNAL DEPENDENCIES. Everything a first-party module needs is in the SDK. Adding
// a dependency here would drag it into the shipped .app and into the GPL compliance
// story, so it is a deliberate decision, not a convenience.

import PackageDescription

/// Applied to every target, test targets included.
///
/// `.v6` already implies complete strict-concurrency checking; `StrictConcurrency` is
/// listed anyway so the intent survives any future change of language mode. Enabling
/// `ExistentialAny` is a real tightening: boxed protocol values must be spelled
/// `any ArchiveEngine`, never bare `ArchiveEngine`, which keeps the cost of an
/// existential visible at the point of use.
let strictSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("StrictConcurrency"),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "ArcSeven",
    platforms: [
        // Matches MACOSX_DEPLOYMENT_TARGET in project.yml. Keep the two in step.
        .macOS(.v14),
    ],
    products: [
        .library(name: "ArchiveCore", targets: ["ArchiveCore"]),
        .library(name: "FMKit", targets: ["FMKit"]),
    ],
    targets: [
        .target(
            name: "ArchiveCore",
            path: "Sources/ArchiveCore",
            swiftSettings: strictSettings
        ),
        .target(
            name: "FMKit",
            dependencies: ["ArchiveCore"],
            path: "Sources/FMKit",
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "ArchiveCoreTests",
            dependencies: ["ArchiveCore"],
            path: "Tests/ArchiveCoreTests",
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "FMKitTests",
            dependencies: ["FMKit", "ArchiveCore"],
            path: "Tests/FMKitTests",
            swiftSettings: strictSettings
        ),
    ]
)
