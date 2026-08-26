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

        // The codec that will actually run. `method == nil` is the dialog's `*`
        // entry: it suppresses the method switch, but a codec still runs, and the
        // dictionary and word-size properties have to be spelled for THAT one.
        let codec = FormatCatalog.effectiveMethod(format: request.format, method: request.method)

        // Dictionary size.
        //
        // The `b` suffix is load-bearing. An unsuffixed `-md=N` is a **log2** value
        // and 7zz rejects anything above 31, so every byte count the dialog can
        // produce died as `E_INVALIDARG` with no archive written. Verified against
        // the vendored 26.02: `-md=16777216` → exit 2, `-md=16777216b` → exit 0 and
        // `Method = LZMA2:24`. `-ms=` below has always had this right.
        //
        // The property NAME varies by codec as well — PPMd sizes a model memory
        // budget through `-mmem=` and rejects `-md=` outright. See
        // `CompressionMethod.dictionaryPropertyName` for the measured table.
        if let bytes = request.dictionarySize.byteValue,
           let property = codec?.dictionaryPropertyName {
            switches.append("-m\(property)=\(bytes)b")
        }

        // Word size.
        //
        // "Word size" is one dialog control standing for two unrelated properties.
        // For the LZ codecs it is fast bytes, `-mfb=`; for PPMd it is the model
        // order, `-mo=`, and PPMd rejects `-mfb=` outright — `-t7z -m0=PPMd -mfb=6`
        // exits 2, `-mo=6` exits 0 and reports `PPMD:o6`. Same in zip. BZip2 and
        // Copy have no such control at all. See
        // `CompressionMethod.wordSizePropertyName` for the measured table.
        if let words = request.wordSize.intValue,
           let property = codec?.wordSizePropertyName {
            switches.append("-m\(property)=\(words)")
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
