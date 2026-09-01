// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte
//
// Make ArcSeven (or something else) the default application for archive types.
//
// Setting `LSHandlerRank` in Info.plist only expresses a preference; the thing that
// actually decides is the user's recorded choice, which is what
// `LSSetDefaultRoleHandlerForContentType` writes. This tool writes it, and can put it
// back.
//
// ⚠️  macOS asks the user to confirm EVERY type, one modal dialog each.
//
//     There are 25 types here, so `set` means 25 dialogs to click through. That is the
//     system's doing, not ours — there is no supported batch API and no way to suppress
//     it — but it is a genuinely unpleasant surprise if nobody warned you. `set` now
//     says so and waits for confirmation before it starts.
//
// Usage:
//   SetDefaultHandler set                 -> ArcSeven becomes the default (25 dialogs)
//   SetDefaultHandler set <bundle-id>     -> something else becomes the default
//   SetDefaultHandler set --yes           -> skip this tool's own confirmation
//   SetDefaultHandler show                -> print the current handler for each type

import Foundation
import CoreServices
import AppKit

let arcSeven = "com.havokentity.ArcSeven"

/// Types ArcSeven will claim.
///
/// Everything here is a container whose contents you want to look at or unpack, which is
/// the only case where "open in an archive manager" is the right double-click behaviour.
let claimed: [String] = [
    "org.7-zip.7-zip-archive",
    "public.zip-archive",
    "com.winzip.zipx-archive",
    "com.rarlab.rar-archive",
    "public.tar-archive",
    "org.gnu.gnu-zip-archive",
    "org.gnu.gnu-zip-tar-archive",
    "public.bzip2-archive",
    "public.tar-bzip2-archive",
    "org.tukaani.xz-archive",
    "org.tukaani.tar-xz-archive",
    "org.tukaani.lzma-archive",
    "com.microsoft.cab",
    "public.cpio-archive",
    "com.apple.bom-compressed-cpio",
    "public.archive.lha",
    "com.microsoft.wim-archive",
    "com.plougher.squashfs-archive",
    "com.facebook.zstandard-archive",
    "com.facebook.zstandard-tar-archive",
    "com.google.brotli-archive",
    "public.lz4-archive",
    "com.allume.stuffit-archive",
    "com.apple.xar-archive",
    "public.iso-image",
]

/// Types ArcSeven declares but deliberately does NOT claim as default, and why.
///
/// Every one of these is a file whose double-click behaviour is *doing something*, not
/// *looking inside*. Hijacking them would technically work and would be actively hostile.
let excluded: [(type: String, reason: String)] = [
    ("public.data",
     "matches every file with no better type - claiming it makes ArcSeven the default for unknown files"),
    ("com.apple.disk-image-udif",
     ".dmg should mount, not open in a browser"),
    ("com.apple.installer-package-archive",
     ".pkg should run Installer"),
    ("com.microsoft.msi-installer",
     "consistent with .pkg; may be handed to a VM"),
    ("com.sun.java-archive",
     ".jar is executable; opening it as a zip would surprise anyone who double-clicks one"),
    ("com.sun.web-application-archive",
     "same reasoning as .jar"),
]

func currentHandler(for type: String) -> String {
    (LSCopyDefaultRoleHandlerForContentType(type as CFString, .viewer)?
        .takeRetainedValue() as String?) ?? "(none)"
}

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "show"

switch command {
case "show":
    print("Claimed types:")
    for type in claimed {
        print("  \(currentHandler(for: type) == arcSeven ? "*" : " ") \(type.padding(toLength: 40, withPad: " ", startingAt: 0)) \(currentHandler(for: type))")
    }
    print("\nDeliberately not claimed:")
    for entry in excluded {
        print("    \(entry.type.padding(toLength: 40, withPad: " ", startingAt: 0)) \(entry.reason)")
    }

case "set":
    let positional = arguments.dropFirst().filter { $0 != "--yes" }
    let target = positional.first ?? arcSeven
    let assumeYes = arguments.contains("--yes")

    // Warn BEFORE the first dialog, not after the twenty-fifth.
    let alreadyMine = claimed.filter { currentHandler(for: $0) == target }.count
    let toChange = claimed.count - alreadyMine
    if toChange == 0 {
        print("All \(claimed.count) types already open with \(target). Nothing to do.")
        exit(0)
    }
    print("This will change \(toChange) file type(s) to open with \(target).")
    print("macOS will ask you to confirm EACH ONE — expect \(toChange) dialogs.")
    print("To undo later:  SetDefaultHandler set <previous-bundle-id>")
    if !assumeYes {
        print("Continue? [y/N] ", terminator: "")
        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        guard answer == "y" || answer == "yes" else { print("Cancelled."); exit(0) }
    }

    var failures = 0
    // Skip types already pointing at the target: each one avoided is one dialog avoided.
    for type in claimed where currentHandler(for: type) != target {
        let status = LSSetDefaultRoleHandlerForContentType(type as CFString, .viewer, target as CFString)
        if status != noErr {
            // A type no handler has ever registered for can legitimately fail; report it
            // rather than pretending everything worked.
            print("  failed \(type) (OSStatus \(status))")
            failures += 1
        }
    }
    print("Set \(toChange - failures)/\(toChange) changed type(s) to \(target).")
    print("LaunchServices takes a moment to flush — re-run `show` if it still reads the old handler.")
    if failures > 0 { print("\(failures) failed - those types may have no registered handler.") }

default:
    print("usage: SetDefaultHandler [show|set [bundle-id]]")
    exit(2)
}
