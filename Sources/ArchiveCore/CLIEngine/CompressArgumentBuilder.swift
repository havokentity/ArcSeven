// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// Translates a `CompressRequest` into `7zz` `-m` switches.
//
// The Windows Add dialog's controls map onto 7-Zip's method-property grammar, which
// is a flat namespace of `-m<name>=<value>` pairs plus a few standalone switches.
// Keeping the translation in one place — rather than scattered through the engine —
// is what lets `docs/FIDELITY.md` state, control by control, which switch each
// dialog field produces.
//
// Ordering matters in one respect: user-supplied `extraParameters` are appended
// last so they override anything the dialog computed, which is exactly how the
// Windows "Parameters" field behaves.

import Foundation

/// Builds the `-m…` switch block for a compression request.
public enum CompressArgumentBuilder {

    /// Method, dictionary, word size, solid block and thread switches.
    public static func methodSwitches(for request: CompressRequest) -> [String] {
        var switches: [String] = []

        // Level. `-mx=N`; 0 means store.
        switches.append("-mx=\(request.level.rawValue)")

        // Method. Only meaningful for formats that offer a choice.
        if let method = request.method, request.level.rawValue > 0 {
            switches.append("-m0=\(method.rawValue)")
        }

        // Dictionary size.
        if let bytes = request.dictionarySize.byteValue {
            switches.append("-md=\(bytes)")
        }

        // Word size.
        if let words = request.wordSize.intValue {
            switches.append("-mfb=\(words)")
        }

        // Solid block size. 7z only; `-ms=off` disables solid mode entirely.
        if request.format == .sevenZip {
            switch request.solidBlockSize {
            case .nonSolid:
                switches.append("-ms=off")
            case .fullySolid:
                switches.append("-ms=on")
            case .bytes(let bytes):
                switches.append("-ms=\(bytes)b")
            case .automatic:
                break
            }
        }

        // Threads.
        if let count = request.threads.intValue {
            switches.append("-mmt=\(count)")
        }

        // Store rather than follow symlinks, when asked.
        if request.storeSymbolicLinks {
            switches.append("-snl")
        }
        if request.storeHardLinks {
            switches.append("-snh")
        }

        return switches
    }

    /// Path-mode and housekeeping switches.
    public static func pathModeSwitches(for request: CompressRequest) -> [String] {
        var switches: [String] = []

        switch request.pathMode {
        case .relative:
            break                       // 7-Zip's default.
        case .full:
            switches.append("-spf")
        case .absolute:
            switches.append("-spf2")
        }

        if request.deleteSourcesAfterCompression {
            switches.append("-sdel")
        }
        if request.setArchiveTimeToLatest {
            switches.append("-stl")
        }

        // Volume splitting. Each size becomes its own `-v` switch, in order.
        for size in request.volumeSizes {
            switches.append("-v\(size)b")
        }

        // User overrides win.
        switches.append(contentsOf: request.extraParameters)

        return switches
    }
}
