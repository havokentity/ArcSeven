// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte
//
// The vocabulary the format catalogue is written in: handler names, and the parameter
// value types a compression request is built from — level, method, dictionary size,
// word size, solid block size, thread count, update mode, encryption method.
//
// FormatCatalog.swift holds the tables that say which of these each handler offers.

import Foundation

/// A 7-Zip archive handler, identified by the handler name `7zz` uses on the wire
/// (`-t<name>`, and the `Type = <name>` property of a listing).
///
/// Open by design, exactly like ``PropID``: 7-Zip registers ~50 handlers and adds
/// more between releases, so an unrecognised handler name must survive round-tripping
/// rather than being dropped.
///
/// Comparison is case-insensitive because `7zz` accepts `-t7z` and reports
/// `Type = 7z`, but reports `Type = Rar5` and `Type = GZip` with mixed case.
public struct ArchiveFormat: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: StringLiteralType) { self.rawValue = value }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue.compare(rhs.rawValue, options: .caseInsensitive) == .orderedSame
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(rawValue.lowercased())
    }

    /// The value to pass to `7zz -t`.
    public var switchValue: String { rawValue }
}

// MARK: - Known handlers

extension ArchiveFormat {
    // The seven creatable formats (res_3 §6 — determined empirically by attempting
    // `a -t<fmt>` against 32 candidate handler names and round-tripping each success
    // through `t` and `x -so`).
    public static let sevenZip: ArchiveFormat = "7z"
    public static let zip: ArchiveFormat      = "zip"
    public static let gzip: ArchiveFormat     = "gzip"
    public static let bzip2: ArchiveFormat    = "bzip2"
    // `xz` is the handler's name, spelled the way 7-Zip spells it, and this is
    // public API. There is nothing clearer to rename it to.
    public static let xz: ArchiveFormat       = "xz" // swiftlint:disable:this identifier_name
    public static let tar: ArchiveFormat      = "tar"
    public static let wim: ArchiveFormat      = "wim"

    // Frequently encountered extract-only handlers, named so callers can refer to
    // them without string literals.
    public static let rar: ArchiveFormat      = "Rar"
    public static let rar5: ArchiveFormat     = "Rar5"
    public static let iso: ArchiveFormat      = "Iso"
    public static let dmg: ArchiveFormat      = "Dmg"
    public static let cab: ArchiveFormat      = "Cab"
    public static let arj: ArchiveFormat      = "Arj"
    public static let lzh: ArchiveFormat      = "Lzh"
    public static let cpio: ArchiveFormat     = "Cpio"
    public static let rpm: ArchiveFormat      = "Rpm"
    public static let deb: ArchiveFormat      = "Ar"
    public static let xar: ArchiveFormat      = "Xar"
    public static let nsis: ArchiveFormat     = "Nsis"
    public static let hfs: ArchiveFormat      = "HFS"
    public static let squashFS: ArchiveFormat = "SquashFS"
    public static let compound: ArchiveFormat = "Compound"
    public static let split: ArchiveFormat    = "Split"
    public static let zstandard: ArchiveFormat = "zstd"
    public static let lzma: ArchiveFormat     = "lzma"
    public static let lzma86: ArchiveFormat   = "lzma86"
    public static let compressZ: ArchiveFormat = "Z"
}

extension ArchiveFormat: CustomStringConvertible {
    public var description: String { rawValue }
}

// MARK: - Compression parameter value types

/// A compression level, 0...9.
///
/// The named levels are the ones 7-Zip labels in the Add dialog; 2, 4, 6 and 8 are
/// selectable and simply show their number (res_8 §1.4).
public struct CompressionLevel: RawRepresentable, Hashable, Sendable, Codable, Comparable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = min(max(rawValue, 0), 9) }
    public init(_ rawValue: Int) { self.init(rawValue: rawValue) }

    public static let store    = Self(0)
    public static let fastest  = Self(1)
    public static let fast     = Self(3)
    public static let normal   = Self(5)
    public static let maximum  = Self(7)
    public static let ultra    = Self(9)

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// The label 7-Zip gives this level, or `nil` for the unnamed even levels.
    public var name: String? {
        switch rawValue {
        case 0: "Store"
        case 1: "Fastest"
        case 3: "Fast"
        case 5: "Normal"
        case 7: "Maximum"
        case 9: "Ultra"
        default: nil
        }
    }

    /// The combo-box text, e.g. `"5 - Normal"` or `"4"` (res_8 §1.4).
    public var displayName: String {
        name.map { "\(rawValue) - \($0)" } ?? "\(rawValue)"
    }
}

/// A compression codec offered by the Add dialog.
///
/// The filters (`BCJ`, `BCJ2`, `Delta`, `ARM64`, `RISCV`, …) are deliberately absent:
/// 7-Zip does not put them in the Method combo either — it applies BCJ/BCJ2
/// automatically for `.7z` at level ≥ 9, and a user who wants to force one types it
/// into the Parameters field (res_8 §1.5).
public enum CompressionMethod: String, Hashable, Sendable, Codable, CaseIterable {
    case copy       = "Copy"
    case lzma       = "LZMA"
    case lzma2      = "LZMA2"
    case ppmd       = "PPMd"
    case bzip2      = "BZip2"
    case deflate    = "Deflate"
    case deflate64  = "Deflate64"
    case gnuTar     = "GNU"
    case posixTar   = "POSIX"

    /// The name to emit in a `-m` property value.
    public var switchValue: String { rawValue }

    /// `true` for the two `tar` "methods", which select a tar dialect rather than a
    /// codec and therefore take no dictionary or word size.
    public var isTarDialect: Bool { self == .gnuTar || self == .posixTar }

    /// `true` when the method's "word size" control is really PPMd's model order
    /// (`-mo=`) rather than fast bytes (`-mfb=`) — res_8 §1.7.
    public var usesModelOrder: Bool { self == .ppmd }

    /// The `-m` property name the Dictionary size control sets, or `nil` when the
    /// codec has no dictionary to size.
    ///
    /// Three different answers, and passing the wrong one is not a mis-tuned
    /// archive — it is `E_INVALIDARG` and no archive at all. Verified against the
    /// vendored 26.02 binary by running `a -t7z -m0=<method>` with each spelling
    /// (0 = accepted, 2 = `E_INVALIDARG`):
    ///
    ///     method       -md=  -mmem=
    ///     LZMA           0      2
    ///     LZMA2          0      2
    ///     BZip2          0      2      (block size, not a window)
    ///     PPMd           2      0      (a model memory budget, not a window)
    ///     Copy           2      2
    ///     Deflate        2      2      (32 KiB window, fixed by the format)
    ///     Deflate64      2      2      (64 KiB window, fixed by the format)
    public var dictionaryPropertyName: String? {
        switch self {
        case .lzma, .lzma2, .bzip2: "d"
        case .ppmd: "mem"
        case .copy, .deflate, .deflate64, .gnuTar, .posixTar: nil
        }
    }

    /// The `-m` property name the Word size control sets, or `nil` when the codec
    /// has no such control.
    ///
    /// Same measurement, same binary, same failure mode as
    /// ``dictionaryPropertyName``:
    ///
    ///     method       -mfb=  -mo=
    ///     LZMA           0      2
    ///     LZMA2          0      2
    ///     Deflate        0      2
    ///     Deflate64      0      2
    ///     PPMd           2      0      (``usesModelOrder``)
    ///     BZip2          2      2
    ///     Copy           2      2
    public var wordSizePropertyName: String? {
        switch self {
        case .lzma, .lzma2, .deflate, .deflate64: "fb"
        case .ppmd: "o"
        case .copy, .bzip2, .gnuTar, .posixTar: nil
        }
    }
}

/// A dictionary size selection: either the handler's own automatic choice or an
/// explicit byte count.
public enum DictionarySize: Hashable, Sendable, Codable {
    case automatic
    case bytes(UInt64)

    public var byteValue: UInt64? {
        if case .bytes(let value) = self { return value }
        return nil
    }
}

/// A word-size (fast bytes) or PPMd model-order selection.
public enum WordSize: Hashable, Sendable, Codable {
    case automatic
    case value(Int)

    public var intValue: Int? {
        if case .value(let value) = self { return value }
        return nil
    }
}

/// A solid-block-size selection (`.7z` and `.xz` only).
public enum SolidBlockSize: Hashable, Sendable, Codable {
    /// Emit nothing; let the handler pick (`*` item, item data `-1`).
    case automatic
    /// `-ms=off` equivalent: every member in its own block (`.7z` only).
    case nonSolid
    /// An explicit block size in bytes.
    case bytes(UInt64)
    /// One block for the whole archive.
    case fullySolid
}

/// A thread-count selection.
public enum ThreadCount: Hashable, Sendable, Codable {
    case automatic
    case count(Int)

    public var intValue: Int? {
        if case .count(let value) = self { return value }
        return nil
    }
}

/// Which members an update operation touches (res_8 §1.12).
public enum UpdateMode: String, Hashable, Sendable, Codable, CaseIterable {
    /// Add new files and replace existing ones. The plain `a` command.
    case addAndReplace
    /// Add new files, replace existing ones only when the source is newer.
    case updateAndAdd
    /// Replace existing members only when the source is newer; add nothing.
    case freshenExisting
    /// Make the archive mirror the source: add, update and delete.
    case synchronize

    /// The label the Add dialog shows.
    public var displayName: String {
        switch self {
        case .addAndReplace:   "Add and replace files"
        case .updateAndAdd:    "Update and add files"
        case .freshenExisting: "Freshen existing files"
        case .synchronize:     "Synchronize files"
        }
    }
}

/// The encryption cipher for a new archive (res_8 §1.16).
public enum ArchiveEncryptionMethod: String, Hashable, Sendable, Codable, CaseIterable {
    /// The only choice for `.7z`, and the strong choice for `.zip`. Emitted as
    /// `-mem=AES256` for zip; for `.7z` it is the default and nothing is emitted.
    case aes256 = "AES-256"
    /// Legacy zip encryption. Weak — offered only because 7-Zip offers it, and it
    /// is the zip default index, so selecting it emits nothing.
    case zipCrypto = "ZipCrypto"

    /// The value to put after `-mem=`, with the dash removed the way 7-Zip's own
    /// `GetEncryptionMethodSpec()` does it.
    public var switchValue: String {
        rawValue.replacingOccurrences(of: "-", with: "")
    }
}
