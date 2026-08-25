// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// Make ArcSeven (or something else) the default application for archive types.
//
// Setting `LSHandlerRank` in Info.plist only expresses a preference; the thing that
// actually decides is the user's recorded choice, which is what
// `LSSetDefaultRoleHandlerForContentType` writes. This tool writes it, and can put it
// back.
//
// Usage:
//   SetDefaultHandler set                 -> ArcSeven becomes the default
//   SetDefaultHandler set <bundle-id>     -> something else becomes the default
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
    let target = arguments.count > 1 ? arguments[1] : arcSeven
    var failures = 0
    for type in claimed {
        let status = LSSetDefaultRoleHandlerForContentType(type as CFString, .viewer, target as CFString)
        if status != noErr {
            // A type no handler has ever registered for can legitimately fail; report it
            // rather than pretending everything worked.
            print("  failed \(type) (OSStatus \(status))")
            failures += 1
        }
    }
    print("Set \(claimed.count - failures)/\(claimed.count) types to \(target).")
    if failures > 0 { print("\(failures) failed - those types may have no registered handler.") }

default:
    print("usage: SetDefaultHandler [show|set [bundle-id]]")
    exit(2)
}
