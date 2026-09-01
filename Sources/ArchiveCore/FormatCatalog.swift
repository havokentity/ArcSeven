// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte
//
// The tables: what `7zz` can write, what it can only read, and which parameter values
// each handler offers. The types the tables are written in live in ArchiveFormat.swift.

import Foundation

/// The authority on what each format can do.
///
/// This is what gates the Add dialog: which formats appear in the picker, which
/// levels/methods/dictionary sizes each offers, and which of the encryption, solid
/// and multi-threading controls are enabled. The tables are transcribed from the
/// static `g_Formats[]` table and the `SetLevel2`/`SetMethod2`/`SetDictionary2`/
/// `SetOrder2` logic described in res_8 §§1.3–1.9, cross-checked against the
/// empirical creatable-format result in res_3 §6.
public enum FormatCatalog {
    // MARK: Creatable formats

    /// Everything `7zz` can write.
    ///
    /// Exactly seven, verified by attempting creation with all 32 candidate handler
    /// names (res_3 §6). Ordered the way the Add dialog orders them: the combo has
    /// `CBS_SORT`, so alphabetically by handler name.
    public static let creatableFormats: [ArchiveFormat] = [
        .sevenZip, .bzip2, .gzip, .tar, .wim, .xz, .zip,
    ]

    /// Per-format capabilities and value enumerations.
    public struct CreatableFormat: Sendable, Hashable {
        public let format: ArchiveFormat
        /// Name for the format picker.
        public let displayName: String
        /// Extension used when generating an output filename.
        public let mainExtension: String
        /// Every extension the handler registers.
        public let extensions: [String]
        /// Levels the format offers, ascending.
        public let levels: [CompressionLevel]
        /// Default level when the user has no saved preference.
        public let defaultLevel: CompressionLevel
        /// Methods in combo order. The first is the "auto" entry, shown with the
        /// `*  ` prefix, and selecting it emits no method property at all.
        public let methods: [CompressionMethod]
        /// `true` when the handler compresses exactly one stream, so it can only be
        /// offered when the selection is a single file, and it appends its extension
        /// to the whole original filename instead of replacing it (`kKeepName`).
        public let keepsName: Bool
        /// `true` for the formats with solid blocks: `.7z` and `.xz`.
        public let supportsSolidBlocks: Bool
        /// `true` when the Non-solid entry appears in the solid combo (`.7z` only).
        public let supportsNonSolid: Bool
        /// `true` when the thread combo is enabled.
        public let supportsMultithreading: Bool
        /// `true` when the Encryption group is enabled: `.7z` and `.zip`.
        public let supportsEncryption: Bool
        /// `true` when `Encrypt file names` is offered: `.7z` only (`-mhe=on`).
        public let supportsEncryptedFileNames: Bool
        /// `true` when a self-extracting stub can be prepended: `.7z` only.
        public let supportsSFX: Bool
        /// `true` when the format can store symbolic links.
        public let supportsSymbolicLinks: Bool
        /// Encryption ciphers offered, first entry being the default (which emits
        /// nothing when selected).
        public let encryptionMethods: [ArchiveEncryptionMethod]
        /// `true` when the format supports in-place update, so the Update-mode combo
        /// is meaningful.
        public let supportsUpdate: Bool

        /// The Add dialog's method combo shows the first method prefixed `*  ` and
        /// treats it as "do not emit a method property".
        public var defaultMethod: CompressionMethod? { methods.first }
    }

    /// Descriptor for a creatable format, or `nil` when the format cannot be created.
    public static func creatable(_ format: ArchiveFormat) -> CreatableFormat? {
        creatableTable.first { $0.format == format }
    }

    /// `true` when `7zz` can write this format.
    public static func canCreate(_ format: ArchiveFormat) -> Bool {
        creatable(format) != nil
    }

    /// Every level 7-Zip accepts, hoisted out of `creatableTable`.
    ///
    /// Inlining `[0, 1, ...].map(CompressionLevel.init)` inside the table literal
    /// makes the type checker give up on the whole expression, so the arrays are
    /// named constants.
    private static let allLevels: [CompressionLevel] =
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9].map { CompressionLevel($0) }

    /// The levels formats with a single knob expose (`store` plus `1...9`).
    private static let standardLevels: [CompressionLevel] = allLevels

    private static let creatableTable: [CreatableFormat] = [
        CreatableFormat(
            format: .sevenZip,
            displayName: "7z",
            mainExtension: "7z",
            extensions: ["7z"],
            levels: allLevels,
            defaultLevel: .normal,
            // Copy, Deflate and Deflate64 are declared in 7-Zip's method table but
            // explicitly skipped for 7z (res_8 §1.5).
            methods: [.lzma2, .lzma, .ppmd, .bzip2],
            keepsName: false,
            supportsSolidBlocks: true,
            supportsNonSolid: true,
            supportsMultithreading: true,
            supportsEncryption: true,
            supportsEncryptedFileNames: true,
            supportsSFX: true,
            supportsSymbolicLinks: true,
            encryptionMethods: [.aes256],
            supportsUpdate: true
        ),
        CreatableFormat(
            format: .bzip2,
            displayName: "bzip2",
            mainExtension: "bz2",
            extensions: ["bz2", "bzip2", "tbz2", "tbz"],
            levels: [1, 3, 5, 7, 9].map { CompressionLevel($0) },
            defaultLevel: .normal,
            methods: [.bzip2],
            keepsName: true,
            supportsSolidBlocks: false,
            supportsNonSolid: false,
            supportsMultithreading: true,
            supportsEncryption: false,
            supportsEncryptedFileNames: false,
            supportsSFX: false,
            supportsSymbolicLinks: false,
            encryptionMethods: [],
            supportsUpdate: false
        ),
        CreatableFormat(
            format: .gzip,
            displayName: "gzip",
            mainExtension: "gz",
            extensions: ["gz", "gzip", "tgz", "tpz"],
            levels: [1, 5, 7, 9].map { CompressionLevel($0) },
            defaultLevel: .normal,
            methods: [.deflate],
            keepsName: true,
            supportsSolidBlocks: false,
            supportsNonSolid: false,
            supportsMultithreading: false,
            supportsEncryption: false,
            supportsEncryptedFileNames: false,
            supportsSFX: false,
            supportsSymbolicLinks: false,
            encryptionMethods: [],
            supportsUpdate: false
        ),
        CreatableFormat(
            format: .tar,
            displayName: "tar",
            mainExtension: "tar",
            extensions: ["tar", "ova"],
            levels: [CompressionLevel(0)],
            defaultLevel: .store,
            methods: [.gnuTar, .posixTar],
            keepsName: false,
            supportsSolidBlocks: false,
            supportsNonSolid: false,
            supportsMultithreading: false,
            supportsEncryption: false,
            supportsEncryptedFileNames: false,
            supportsSFX: false,
            supportsSymbolicLinks: true,
            encryptionMethods: [],
            supportsUpdate: true
        ),
        CreatableFormat(
            format: .wim,
            displayName: "wim",
            mainExtension: "wim",
            extensions: ["wim", "swm", "esd", "ppkg"],
            levels: [CompressionLevel(0)],
            defaultLevel: .store,
            methods: [],
            keepsName: false,
            supportsSolidBlocks: false,
            supportsNonSolid: false,
            supportsMultithreading: false,
            supportsEncryption: false,
            supportsEncryptedFileNames: false,
            supportsSFX: false,
            supportsSymbolicLinks: true,
            encryptionMethods: [],
            supportsUpdate: true
        ),
        CreatableFormat(
            format: .xz,
            displayName: "xz",
            mainExtension: "xz",
            extensions: ["xz", "txz"],
            // Store is not supported by xz, so level 0 is absent.
            levels: [1, 2, 3, 4, 5, 6, 7, 8, 9].map { CompressionLevel($0) },
            defaultLevel: .normal,
            methods: [.lzma2],
            keepsName: true,
            supportsSolidBlocks: true,
            supportsNonSolid: false,
            supportsMultithreading: true,
            supportsEncryption: false,
            supportsEncryptedFileNames: false,
            supportsSFX: false,
            supportsSymbolicLinks: false,
            encryptionMethods: [],
            supportsUpdate: false
        ),
        CreatableFormat(
            format: .zip,
            displayName: "zip",
            mainExtension: "zip",
            extensions: [
                "zip", "z01", "zipx", "jar", "xpi", "odt", "ods",
                "docx", "xlsx", "epub", "ipa", "apk", "appx",
            ],
            levels: [0, 1, 3, 5, 7, 9].map { CompressionLevel($0) },
            defaultLevel: .normal,
            methods: [.deflate, .deflate64, .bzip2, .lzma, .ppmd],
            keepsName: false,
            supportsSolidBlocks: false,
            supportsNonSolid: false,
            supportsMultithreading: true,
            supportsEncryption: true,
            supportsEncryptedFileNames: false,
            supportsSFX: false,
            supportsSymbolicLinks: false,
            encryptionMethods: [.zipCrypto, .aes256],
            supportsUpdate: true
        ),
    ]
}

// MARK: - Parameter tables

extension FormatCatalog {
    // MARK: Dictionary sizes

    private static let kibibyte: UInt64 = 1 << 10
    private static let mebibyte: UInt64 = 1 << 20

    /// LZMA / LZMA2 dictionary sizes on a 64-bit host, ascending.
    ///
    /// Upstream builds this list arithmetically (`dict = (2 + (i & 1)) << (i / 2)`
    /// over `i = 30...62`, skipping `i < 38 && i ∉ {30, 34}` and `i == 39`, clamped
    /// to `kLzmaMaxDictSize = 15 << 28`). The resulting values are enumerated here
    /// literally because the sequence is a fixed UI enumeration, not a computation
    /// anyone benefits from re-deriving at runtime.
    public static let lzmaDictionarySizes: [UInt64] = [
        64 * kibibyte, 256 * kibibyte,
        1 * mebibyte, 2 * mebibyte, 3 * mebibyte, 4 * mebibyte, 6 * mebibyte,
        8 * mebibyte, 12 * mebibyte, 16 * mebibyte, 24 * mebibyte, 32 * mebibyte,
        48 * mebibyte, 64 * mebibyte, 96 * mebibyte, 128 * mebibyte,
        192 * mebibyte, 256 * mebibyte, 384 * mebibyte, 512 * mebibyte,
        768 * mebibyte, 1024 * mebibyte, 1536 * mebibyte, 2048 * mebibyte,
        3072 * mebibyte, 3840 * mebibyte,
    ]

    /// PPMd dictionary ("memory") sizes inside `.7z`, ascending.
    public static let ppmd7zDictionarySizes: [UInt64] = [
        1 * mebibyte, 2 * mebibyte, 3 * mebibyte, 4 * mebibyte, 6 * mebibyte,
        8 * mebibyte, 12 * mebibyte, 16 * mebibyte, 24 * mebibyte, 32 * mebibyte,
        48 * mebibyte, 64 * mebibyte, 96 * mebibyte, 128 * mebibyte,
        192 * mebibyte, 256 * mebibyte, 384 * mebibyte, 512 * mebibyte,
        768 * mebibyte, 1024 * mebibyte,
    ]

    /// PPMd memory sizes inside `.zip` — plain powers of two, 1 MiB to 256 MiB.
    public static let ppmdZipDictionarySizes: [UInt64] =
        (20...28).map { UInt64(1) << $0 }

    /// BZip2 block sizes. 7-Zip labels these in KiB and emits `i * 100 << 10`, even
    /// though bzip2's real block unit is 100 000 bytes (res_8 §1.6).
    public static let bzip2BlockSizes: [UInt64] = (1...9).map { UInt64($0) * 100 * kibibyte }

    /// Dictionary sizes offered for a given format and method, ascending.
    ///
    /// Returns an empty array when the dictionary combo is disabled — which is the
    /// case at level 0 for every non-tar format, and always for `wim`.
    public static func dictionarySizes(
        format: ArchiveFormat,
        method: CompressionMethod?,
        level: CompressionLevel
    ) -> [UInt64] {
        guard let method = effectiveMethod(format: format, method: method) else { return [] }
        // At Store the method/dictionary/word combos are cleared outright, except
        // for tar which has no compression controls at all (res_8 §1.5).
        if level.rawValue == 0 && format != .tar { return [] }

        switch method {
        case .lzma, .lzma2:
            return lzmaDictionarySizes
        case .ppmd:
            return format == .zip ? ppmdZipDictionarySizes : ppmd7zDictionarySizes
        case .bzip2:
            return bzip2BlockSizes
        case .deflate:
            return [32 * kibibyte]      // fixed; combo shows one item and is disabled
        case .deflate64:
            return [64 * kibibyte]      // fixed
        case .copy, .gnuTar, .posixTar:
            return []
        }
    }

    /// The dictionary size the handler would choose for itself.
    ///
    /// Shown as the `*  <size>` auto entry. `nil` when the method has no dictionary.
    public static func automaticDictionarySize(
        format: ArchiveFormat,
        method: CompressionMethod?,
        level: CompressionLevel
    ) -> UInt64? {
        guard let method = effectiveMethod(format: format, method: method) else { return nil }
        let value = level.rawValue

        switch method {
        case .lzma, .lzma2:
            // Upstream: level<=4 → 1 << (level*2 + 16);
            //           level <= sizeof(size_t)/2 + 4 → 1 << (level + 20);
            //           otherwise 1 << (sizeof(size_t)/2 + 24).
            // On a 64-bit host sizeof(size_t)/2 == 4, so the caps are level 8 and 1<<28.
            if value <= 4 { return UInt64(1) << (value * 2 + 16) }
            if value <= 8 { return UInt64(1) << (value + 20) }
            return UInt64(1) << 28
        case .ppmd:
            return UInt64(1) << (value + 19)
        case .bzip2:
            if value >= 5 { return 900 * kibibyte }
            if value >= 3 { return 500 * kibibyte }
            return 100 * kibibyte
        case .deflate:
            return 32 * kibibyte
        case .deflate64:
            return 64 * kibibyte
        case .copy, .gnuTar, .posixTar:
            return nil
        }
    }

    // MARK: Word sizes

    /// Word sizes ("fast bytes", or PPMd model order) offered for a method.
    public static func wordSizes(
        format: ArchiveFormat,
        method: CompressionMethod?,
        level: CompressionLevel
    ) -> [Int] {
        guard let method = effectiveMethod(format: format, method: method) else { return [] }
        if level.rawValue == 0 && format != .tar { return [] }

        switch method {
        case .lzma, .lzma2:
            return [8, 12, 16, 24, 32, 48, 64, 96, 128, 192, 256, 273]
        case .deflate:
            return [8, 12, 16, 24, 32, 48, 64, 96, 128, 192, 256, 258]
        case .deflate64:
            return [8, 12, 16, 24, 32, 48, 64, 96, 128, 192, 256, 257]
        case .ppmd:
            return format == .zip
                ? Array(2...16)
                : [2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 20, 24, 28, 32]
        case .bzip2, .copy, .gnuTar, .posixTar:
            return []
        }
    }

    /// The word size the handler would choose for itself.
    public static func automaticWordSize(
        format: ArchiveFormat,
        method: CompressionMethod?,
        level: CompressionLevel
    ) -> Int? {
        guard let method = effectiveMethod(format: format, method: method) else { return nil }
        let value = level.rawValue

        switch method {
        case .lzma, .lzma2:
            return value < 7 ? 32 : 64
        case .deflate, .deflate64:
            if value >= 9 { return 128 }
            if value >= 7 { return 64 }
            return 32
        case .ppmd:
            if format == .zip { return value + 3 }
            if value >= 9 { return 32 }
            if value >= 7 { return 16 }
            if value >= 5 { return 6 }
            return 4
        case .bzip2, .copy, .gnuTar, .posixTar:
            return nil
        }
    }

    // MARK: Solid block sizes

    /// Explicit solid-block sizes offered, ascending: 1 MiB through 64 GiB.
    ///
    /// The combo also carries `*  <auto>`, `Non-solid` (`.7z` only) and `Solid`,
    /// which are modelled by the other ``SolidBlockSize`` cases rather than by
    /// magic byte values.
    public static let solidBlockSizes: [UInt64] = (20...36).map { UInt64(1) << $0 }

    /// The solid-block choices a format offers, in Add-dialog order.
    public static func solidBlockOptions(format: ArchiveFormat, level: CompressionLevel) -> [SolidBlockSize] {
        guard let descriptor = creatable(format), descriptor.supportsSolidBlocks else { return [] }
        if level.rawValue == 0 { return [] }
        var options: [SolidBlockSize] = [.automatic]
        if descriptor.supportsNonSolid { options.append(.nonSolid) }
        options.append(contentsOf: solidBlockSizes.map(SolidBlockSize.bytes))
        options.append(.fullySolid)
        return options
    }

    // MARK: Threads

    /// The largest thread count the codec itself can use (26.02 values, res_8 §1.9).
    ///
    /// The Add dialog offers `1...min(hardwareThreads * 2, this)`; the automatic
    /// entry is `min(hardwareThreads, this)`, further reduced when the memory
    /// estimate exceeds the configured limit.
    public static func maximumThreads(format: ArchiveFormat, method: CompressionMethod?) -> Int {
        guard let descriptor = creatable(format), descriptor.supportsMultithreading else { return 1 }
        guard let method = effectiveMethod(format: format, method: method) else { return 1 }
        switch method {
        case .lzma2:
            return format == .xz ? 512 : 512
        case .lzma:
            return 2
        case .bzip2:
            return 64
        case .deflate, .deflate64, .ppmd, .copy:
            // Zip parallelises across *members* even when the codec is
            // single-threaded, so the zip handler still offers a thread count.
            return format == .zip ? 128 : 1
        case .gnuTar, .posixTar:
            return 1
        }
    }

    /// The default thread count for a machine with `hardwareThreads` cores.
    public static func automaticThreads(
        format: ArchiveFormat,
        method: CompressionMethod?,
        hardwareThreads: Int = ProcessInfo.processInfo.activeProcessorCount
    ) -> Int {
        max(1, min(hardwareThreads, maximumThreads(format: format, method: method)))
    }

    // MARK: Update modes

    /// Update modes offered for a format. Formats that rewrite their single stream
    /// wholesale (gzip, bzip2, xz) offer only `addAndReplace`.
    public static func updateModes(format: ArchiveFormat) -> [UpdateMode] {
        guard let descriptor = creatable(format), descriptor.supportsUpdate else {
            return [.addAndReplace]
        }
        return UpdateMode.allCases
    }

    // MARK: Helpers

    /// Resolve `nil` (the `*` auto entry) to the format's default method.
    ///
    /// Public because the argument builder needs it too: selecting `*` suppresses the
    /// method switch, but the handler still runs *a* codec, and the dictionary and
    /// word-size properties have to be spelled for that one. `-md=` against a zip
    /// left on `*` is `-md=` against Deflate, which is `E_INVALIDARG`.
    public static func effectiveMethod(
        format: ArchiveFormat,
        method: CompressionMethod?
    ) -> CompressionMethod? {
        if let method { return method }
        return creatable(format)?.defaultMethod
    }
}

// MARK: - Extract-only handlers

extension FormatCatalog {
    // MARK: Extract-only formats

    /// Handlers `7zz` can read but not write.
    ///
    /// Transcribed from the verified `7zz i` handler dump (res_3 §6). RAR and RAR5
    /// appear here and *only* here: creating RAR archives is forbidden by the unRAR
    /// licence's clause 2, and the UI must never offer it.
    public static let extractOnlyFormats: [ExtractOnlyFormat] = [
        ExtractOnlyFormat("APM", extensions: ["apm"]),
        ExtractOnlyFormat("Ar", extensions: ["ar", "a", "deb", "lib"]),
        ExtractOnlyFormat("Arj", extensions: ["arj"]),
        ExtractOnlyFormat("Cab", extensions: ["cab"]),
        ExtractOnlyFormat("Chm", extensions: ["chm", "chi", "chq", "chw"]),
        ExtractOnlyFormat("COFF", extensions: ["obj"]),
        ExtractOnlyFormat("Compound", extensions: ["msi", "msp", "doc", "xls", "ppt"]),
        ExtractOnlyFormat("Cpio", extensions: ["cpio"]),
        ExtractOnlyFormat("CramFS", extensions: ["cramfs"]),
        ExtractOnlyFormat("Dmg", extensions: ["dmg"]),
        ExtractOnlyFormat("ELF", extensions: ["elf"]),
        ExtractOnlyFormat("Ext", extensions: ["ext", "ext2", "ext3", "ext4", "img"]),
        ExtractOnlyFormat("FAT", extensions: ["fat", "img"]),
        ExtractOnlyFormat("FLV", extensions: ["flv"]),
        ExtractOnlyFormat("GPT", extensions: ["gpt", "mbr"]),
        ExtractOnlyFormat("HFS", extensions: ["hfs", "hfsx"]),
        ExtractOnlyFormat("Hxs", extensions: ["hxs", "hxi", "hxr", "hxq", "hxw", "lit"]),
        ExtractOnlyFormat("IHex", extensions: ["ihex"]),
        ExtractOnlyFormat("Iso", extensions: ["iso", "img"]),
        ExtractOnlyFormat("Lzh", extensions: ["lzh", "lha"]),
        ExtractOnlyFormat("lzma", extensions: ["lzma"]),
        ExtractOnlyFormat("lzma86", extensions: ["lzma86"]),
        ExtractOnlyFormat("MachO", extensions: ["macho"]),
        ExtractOnlyFormat("MBR", extensions: ["mbr"]),
        ExtractOnlyFormat("MsLZ", extensions: ["mslz"]),
        ExtractOnlyFormat("Mub", extensions: ["mub"]),
        ExtractOnlyFormat("Nsis", extensions: ["nsis", "exe"]),
        ExtractOnlyFormat("NTFS", extensions: ["ntfs", "img"]),
        ExtractOnlyFormat("PE", extensions: ["exe", "dll", "sys"]),
        ExtractOnlyFormat("Ppmd", extensions: ["ppmd"]),
        ExtractOnlyFormat("QCOW", extensions: ["qcow", "qcow2", "qcow2c"]),
        ExtractOnlyFormat("Rar", extensions: ["rar", "r00"], notes: .unrarRestricted),
        ExtractOnlyFormat("Rar5", extensions: ["rar", "r00"], notes: .unrarRestricted),
        ExtractOnlyFormat("Rpm", extensions: ["rpm"]),
        ExtractOnlyFormat("Split", extensions: ["001"]),
        ExtractOnlyFormat("SquashFS", extensions: ["squashfs"]),
        ExtractOnlyFormat("SWF", extensions: ["swf"]),
        ExtractOnlyFormat("SWFc", extensions: ["swf"]),
        ExtractOnlyFormat("TE", extensions: ["te"]),
        ExtractOnlyFormat("Udf", extensions: ["udf", "iso", "img"]),
        ExtractOnlyFormat("UEFIc", extensions: ["scap"]),
        ExtractOnlyFormat("UEFIf", extensions: ["uefif"]),
        ExtractOnlyFormat("VDI", extensions: ["vdi"]),
        ExtractOnlyFormat("VHD", extensions: ["vhd"]),
        ExtractOnlyFormat("VMDK", extensions: ["vmdk"]),
        ExtractOnlyFormat("Xar", extensions: ["xar", "pkg", "xip"]),
        ExtractOnlyFormat("Z", extensions: ["z", "taz"]),
        ExtractOnlyFormat("zstd", extensions: ["zst", "tzst"]),
    ]

    /// A handler that can be read but not written.
    public struct ExtractOnlyFormat: Sendable, Hashable {
        public let format: ArchiveFormat
        public let extensions: [String]
        public let notes: Notes

        /// Licence-relevant facts about a handler.
        public enum Notes: String, Sendable, Hashable {
            /// Nothing applies beyond the LGPL. The raw value stays `"none"` so the
            /// serialised form does not move when the case is renamed.
            case unrestricted = "none"
            /// Decoding is governed by the unRAR licence in addition to the LGPL.
            /// Extraction is explicitly permitted; creating a RAR-compatible
            /// archiver is not, so no create affordance may ever exist for this
            /// handler, and the verbatim unRAR clause must ship in the bundle.
            case unrarRestricted
        }

        public init(_ name: String, extensions: [String], notes: Notes = .unrestricted) {
            self.format = ArchiveFormat(name)
            self.extensions = extensions
            self.notes = notes
        }
    }

    /// `true` when `7zz` has a handler that can read this format.
    public static func canExtract(_ format: ArchiveFormat) -> Bool {
        canCreate(format) || extractOnlyFormats.contains { $0.format == format }
    }

    // MARK: Extension lookup

    /// Guess the handler for a filename extension.
    ///
    /// A guess only: `7zz` sniffs content and its answer wins. Ambiguous extensions
    /// (`.img`, `.exe`) resolve to the first registered handler, exactly as the
    /// format picker would show them.
    public static func format(forPathExtension pathExtension: String) -> ArchiveFormat? {
        let needle = pathExtension.lowercased()
        guard !needle.isEmpty else { return nil }
        if let match = creatableTable.first(where: { $0.extensions.contains(needle) }) {
            return match.format
        }
        return extractOnlyFormats.first { $0.extensions.contains(needle) }?.format
    }

    /// Compound two-pass targets: `tar` first, then a single-stream compressor.
    ///
    /// `.tar.gz` and friends are genuinely two archives (res_3 §4a.10), so the Add
    /// dialog offers them as their own picker entries and the engine runs two passes.
    public struct CompoundFormat: Sendable, Hashable {
        public let displayName: String
        public let pathExtension: String
        public let outerFormat: ArchiveFormat

        public init(displayName: String, pathExtension: String, outerFormat: ArchiveFormat) {
            self.displayName = displayName
            self.pathExtension = pathExtension
            self.outerFormat = outerFormat
        }
    }

    /// The tar-plus-compressor combinations the picker offers.
    public static let compoundFormats: [CompoundFormat] = [
        CompoundFormat(displayName: "tar.gz", pathExtension: "tar.gz", outerFormat: .gzip),
        CompoundFormat(displayName: "tar.bz2", pathExtension: "tar.bz2", outerFormat: .bzip2),
        CompoundFormat(displayName: "tar.xz", pathExtension: "tar.xz", outerFormat: .xz),
    ]
}
