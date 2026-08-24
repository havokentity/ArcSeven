// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte

import Foundation

// MARK: - Shared enumerations

/// Where extracted files land relative to the destination directory.
///
/// Mirrors 7-Zip's `NExtract::NPathMode` (res_8 §2.2). Note that the Extract dialog
/// offers only three of the four: `current` is the mode the File Manager uses when
/// you extract a selection from *inside* an open archive, and it is never directly
/// selectable.
public enum ExtractPathMode: String, Hashable, Sendable, Codable, CaseIterable {
    /// Recreate the full stored directory tree under the destination. `-spf` is not
    /// involved; this is `7zz x`.
    case fullPaths
    /// Strip the prefix of the directory currently being browsed, keeping paths
    /// below it. Not offered in the Extract dialog, but preserved when the caller
    /// asks for it and the user leaves the combo on Full pathnames.
    case currentPaths
    /// Flatten: write every member into the destination directory with no
    /// subdirectories. This is `7zz e`.
    case noPaths
    /// Recreate the path including its root/volume component.
    case absolutePaths

    /// The label the Extract dialog shows, or `nil` for the non-selectable mode.
    public var displayName: String? {
        switch self {
        case .fullPaths:     "Full pathnames"
        case .currentPaths:  nil
        case .noPaths:       "No pathnames"
        case .absolutePaths: "Absolute pathnames"
        }
    }

    /// The modes the Extract dialog lists, in dialog order.
    public static var selectableCases: [ExtractPathMode] {
        [.fullPaths, .noPaths, .absolutePaths]
    }
}

/// What to do when an extracted file already exists on disk.
///
/// Mirrors `NExtract::NOverwriteMode` (res_8 §2.3).
public enum OverwriteMode: String, Hashable, Sendable, Codable, CaseIterable {
    /// Stop and ask. The engine cannot answer this itself: it must be resolved by
    /// the UI *before* spawning, because a `7zz` that prompts with a closed stdin
    /// exits 255 and is indistinguishable from a user cancellation (res_3 §4a.8).
    case ask
    /// Overwrite silently.
    case overwrite
    /// Leave the existing file and skip the incoming one.
    case skip
    /// Rename the **incoming** file: `name_1.ext`, `name_2.ext`, …
    case autoRename
    /// Rename the **existing** file and write the incoming one under the original name.
    case autoRenameExisting

    /// The label the Extract dialog shows.
    public var displayName: String {
        switch self {
        case .ask:               "Ask before overwrite"
        case .overwrite:         "Overwrite without prompt"
        case .skip:              "Skip existing files"
        case .autoRename:        "Auto rename"
        case .autoRenameExisting: "Auto rename existing files"
        }
    }
}

/// How much of each source path is stored inside a new archive.
///
/// Mirrors `NWildcard::ECensorPathMode` (res_8 §1.13).
public enum CompressPathMode: String, Hashable, Sendable, Codable, CaseIterable {
    /// Store paths relative to the directory being compressed from. The default,
    /// and almost always what a GUI user means.
    case relative
    /// Keep directories below the volume root but drop the root itself.
    case full
    /// Store the complete absolute path, root included.
    case absolute

    public var displayName: String {
        switch self {
        case .relative: "Relative pathnames"
        case .full:     "Full pathnames"
        case .absolute: "Absolute pathnames"
        }
    }
}

/// Digest algorithms `7zz h` can compute.
public enum HashAlgorithm: String, Hashable, Sendable, Codable, CaseIterable {
    case crc32   = "CRC32"
    case crc64   = "CRC64"
    case sha1    = "SHA1"
    case sha256  = "SHA256"
    case sha384  = "SHA384"
    case sha512  = "SHA512"
    case sha3_256 = "SHA3-256"
    case blake2sp = "BLAKE2sp"
    case xxh64   = "XXH64"
    case md5     = "MD5"

    /// The value to pass after `-scrc`.
    public var switchValue: String { rawValue }

    /// Human-facing name for the CRC menu.
    public var displayName: String {
        switch self {
        case .crc32:    "CRC-32"
        case .crc64:    "CRC-64"
        case .sha1:     "SHA-1"
        case .sha256:   "SHA-256"
        case .sha384:   "SHA-384"
        case .sha512:   "SHA-512"
        case .sha3_256: "SHA3-256"
        case .blake2sp: "BLAKE2sp"
        case .xxh64:    "XXH64"
        case .md5:      "MD5"
        }
    }
}

// MARK: - Read requests

/// Ask an engine to enumerate an archive.
public struct ListRequest: Sendable, Hashable {
    /// The archive to open. For a split set this must be the `.001` volume.
    public var archiveURL: URL

    /// Force a handler instead of letting `7zz` sniff the content.
    ///
    /// Needed for headerless streams — reading a `.tar` off stdin requires
    /// `-ttar`, for instance (res_3 §4a.10).
    public var formatOverride: ArchiveFormat?

    /// Password for a header-encrypted archive.
    ///
    /// Delivered to `7zz` on **stdin**, never on argv, so it does not appear in
    /// `ps` output. See the security note on ``CompressRequest/encryption``, which
    /// cannot do the same.
    public var password: String?

    /// Interpret timestamps in this zone. `7zz l -slt` prints wall-clock local time
    /// with no zone marker (res_3 §4a.4).
    public var timeZone: TimeZone

    public init(
        archiveURL: URL,
        formatOverride: ArchiveFormat? = nil,
        password: String? = nil,
        timeZone: TimeZone = .current
    ) {
        self.archiveURL = archiveURL
        self.formatOverride = formatOverride
        self.password = password
        self.timeZone = timeZone
    }
}

/// Ask an engine to unpack members to disk.
public struct ExtractRequest: Sendable, Hashable {
    /// The archive to read.
    public var archiveURL: URL

    /// Directory to write into. Created if it does not exist.
    public var destinationURL: URL

    /// How much of each stored path to recreate.
    public var pathMode: ExtractPathMode

    /// What to do about files that already exist.
    ///
    /// ``OverwriteMode/ask`` must be resolved by the caller before the engine
    /// spawns anything; an engine that receives it will reject the request rather
    /// than deadlock on a prompt (res_3 §4a.8).
    public var overwriteMode: OverwriteMode

    /// Password for an encrypted archive. Sent on stdin.
    public var password: String?

    /// Members to extract, as archive-relative paths. `nil` or empty means
    /// everything.
    ///
    /// Passed to `7zz` through an `@listfile` with `-scsUTF-8`, never as argv:
    /// `ARG_MAX` on macOS is roughly 1 MiB and a few thousand long paths will blow
    /// through it with an `E2BIG` that surfaces as an opaque spawn failure
    /// (res_3 §4a.10).
    public var selectedEntries: [String]?

    /// Force a handler instead of content sniffing.
    public var formatOverride: ArchiveFormat?

    /// Drop a single top-level directory whose name matches the archive, so the
    /// user does not get `Foo/Foo/…` (`-spe`).
    public var eliminateRootDuplication: Bool

    /// Recreate symbolic links as links rather than as copies of their targets
    /// (`-snl`).
    public var restoreSymbolicLinks: Bool

    /// Keep the partial output of members that fail CRC, instead of deleting them.
    /// Useful for salvage; off by default because partial files are a footgun.
    public var keepBrokenFiles: Bool

    public init(
        archiveURL: URL,
        destinationURL: URL,
        pathMode: ExtractPathMode = .fullPaths,
        overwriteMode: OverwriteMode = .overwrite,
        password: String? = nil,
        selectedEntries: [String]? = nil,
        formatOverride: ArchiveFormat? = nil,
        eliminateRootDuplication: Bool = false,
        restoreSymbolicLinks: Bool = true,
        keepBrokenFiles: Bool = false
    ) {
        self.archiveURL = archiveURL
        self.destinationURL = destinationURL
        self.pathMode = pathMode
        self.overwriteMode = overwriteMode
        self.password = password
        self.selectedEntries = selectedEntries
        self.formatOverride = formatOverride
        self.eliminateRootDuplication = eliminateRootDuplication
        self.restoreSymbolicLinks = restoreSymbolicLinks
        self.keepBrokenFiles = keepBrokenFiles
    }
}

/// Ask an engine to verify an archive without writing anything.
///
/// Test is extraction to `/dev/null` with CRC verification, and works on every
/// readable format (res_3 §6).
public struct TestRequest: Sendable, Hashable {
    public var archiveURL: URL
    public var selectedEntries: [String]?
    public var password: String?
    public var formatOverride: ArchiveFormat?

    public init(
        archiveURL: URL,
        selectedEntries: [String]? = nil,
        password: String? = nil,
        formatOverride: ArchiveFormat? = nil
    ) {
        self.archiveURL = archiveURL
        self.selectedEntries = selectedEntries
        self.password = password
        self.formatOverride = formatOverride
    }
}

/// Ask an engine to stream one member's bytes without touching the filesystem.
///
/// Backed by `7zz x -so`, which is what makes Quick Look previews and in-app
/// viewers possible without a temp file (res_3 §4a.10).
public struct ReadEntryRequest: Sendable, Hashable {
    public var archiveURL: URL
    /// Archive-relative path of the member to stream.
    public var entryPath: String
    public var password: String?
    public var formatOverride: ArchiveFormat?
    /// Refuse to stream a member larger than this, so a preview cannot be tricked
    /// into buffering a decompression bomb. `nil` disables the guard.
    public var maximumByteCount: UInt64?

    public init(
        archiveURL: URL,
        entryPath: String,
        password: String? = nil,
        formatOverride: ArchiveFormat? = nil,
        maximumByteCount: UInt64? = 256 << 20
    ) {
        self.archiveURL = archiveURL
        self.entryPath = entryPath
        self.password = password
        self.formatOverride = formatOverride
        self.maximumByteCount = maximumByteCount
    }
}

// MARK: - Write requests

/// Ask an engine to create or update an archive.
///
/// Every field maps onto a control in 7-Zip's Add dialog (res_8 §1), so the dialog
/// can be a thin editor over this value.
public struct CompressRequest: Sendable, Hashable {
    /// The archive to write. Its extension is not authoritative — ``format`` is.
    public var archiveURL: URL

    /// Files and directories to add.
    public var inputs: [URL]

    /// Directory the stored paths are made relative to when ``pathMode`` is
    /// ``CompressPathMode/relative``.
    ///
    /// The engine chdirs here and passes relative paths, which is both simpler and
    /// safer than `-spf` games (res_3 §4a.10). When `nil` the engine uses the
    /// deepest common ancestor of ``inputs``.
    public var baseDirectory: URL?

    public var format: ArchiveFormat
    public var level: CompressionLevel

    /// `nil` selects the format's `*` auto entry and emits no method property.
    public var method: CompressionMethod?

    public var dictionarySize: DictionarySize
    public var wordSize: WordSize
    public var solidBlockSize: SolidBlockSize
    public var threads: ThreadCount

    /// Which members the operation adds, replaces or removes.
    public var updateMode: UpdateMode

    /// How much of each source path is stored.
    public var pathMode: CompressPathMode

    /// Encryption settings, or `nil` for an unencrypted archive.
    ///
    /// - Important: An empty password means "no encryption", exactly as in 7-Zip.
    ///   Set this to `nil` rather than to an ``EncryptionOptions`` with an empty
    ///   password, so the intent is unambiguous at the call site.
    public var encryption: EncryptionOptions?

    /// Volume sizes in bytes. The last value repeats for all remaining volumes,
    /// matching 7-Zip's space-separated `-v` grammar (res_8 §1.14). Empty means one
    /// file.
    public var volumeSizes: [UInt64]

    /// Extra `-m` properties, already split into tokens.
    ///
    /// Appended after everything the structured fields produce, so they override
    /// them — the same precedence 7-Zip's Parameters field has. Tokens may be
    /// written with or without the leading `-m`; the engine normalises them.
    public var extraParameters: [String]

    /// Delete the sources once compression succeeds (`-sdel`).
    ///
    /// - Warning: Destructive and irreversible. Gate behind an explicit confirmation
    ///   every time; never persist it as a sticky preference.
    public var deleteSourcesAfterCompression: Bool

    /// Store symbolic links as links rather than following them (`-snl`).
    public var storeSymbolicLinks: Bool

    /// Store hard links as links (`-snh`).
    public var storeHardLinks: Bool

    /// Set the archive's own mtime to the newest member's mtime (`-stl`).
    public var setArchiveTimeToLatest: Bool

    /// Timestamp fields to store, and at what precision.
    public var timestamps: TimestampOptions

    /// Prepend a self-extracting stub. `.7z` only, and only with Copy/LZMA/LZMA2/PPMd.
    public var selfExtractingModuleURL: URL?

    public init(
        archiveURL: URL,
        inputs: [URL],
        baseDirectory: URL? = nil,
        format: ArchiveFormat = .sevenZip,
        level: CompressionLevel = .normal,
        method: CompressionMethod? = nil,
        dictionarySize: DictionarySize = .automatic,
        wordSize: WordSize = .automatic,
        solidBlockSize: SolidBlockSize = .automatic,
        threads: ThreadCount = .automatic,
        updateMode: UpdateMode = .addAndReplace,
        pathMode: CompressPathMode = .relative,
        encryption: EncryptionOptions? = nil,
        volumeSizes: [UInt64] = [],
        extraParameters: [String] = [],
        deleteSourcesAfterCompression: Bool = false,
        storeSymbolicLinks: Bool = true,
        storeHardLinks: Bool = false,
        setArchiveTimeToLatest: Bool = false,
        timestamps: TimestampOptions = TimestampOptions(),
        selfExtractingModuleURL: URL? = nil
    ) {
        self.archiveURL = archiveURL
        self.inputs = inputs
        self.baseDirectory = baseDirectory
        self.format = format
        self.level = level
        self.method = method
        self.dictionarySize = dictionarySize
        self.wordSize = wordSize
        self.solidBlockSize = solidBlockSize
        self.threads = threads
        self.updateMode = updateMode
        self.pathMode = pathMode
        self.encryption = encryption
        self.volumeSizes = volumeSizes
        self.extraParameters = extraParameters
        self.deleteSourcesAfterCompression = deleteSourcesAfterCompression
        self.storeSymbolicLinks = storeSymbolicLinks
        self.storeHardLinks = storeHardLinks
        self.setArchiveTimeToLatest = setArchiveTimeToLatest
        self.timestamps = timestamps
        self.selfExtractingModuleURL = selfExtractingModuleURL
    }
}

extension CompressRequest {
    /// Encryption settings for a new archive.
    public struct EncryptionOptions: Sendable, Hashable {
        /// The passphrase. Must be non-empty; an empty passphrase means 7-Zip
        /// writes a plaintext archive with a success exit code.
        public var password: String

        /// Encrypt the archive's file *names* as well as its data (`-mhe=on`).
        ///
        /// `.7z` only. Without it, anyone can list the archive and see every path,
        /// size and timestamp without the password.
        public var encryptFileNames: Bool

        /// The cipher. `.aes256` is the only choice for `.7z`; `.zip` also offers
        /// the legacy `.zipCrypto`.
        public var method: ArchiveEncryptionMethod

        public init(
            password: String,
            encryptFileNames: Bool = true,
            method: ArchiveEncryptionMethod = .aes256
        ) {
            self.password = password
            self.encryptFileNames = encryptFileNames
            self.method = method
        }

        /// `true` when the settings would actually encrypt anything.
        public var isEffective: Bool { !password.isEmpty }
    }

    /// Which timestamps to store and at what resolution (res_8 §1.17).
    public struct TimestampOptions: Sendable, Hashable {
        /// Sub-second resolution the format should record, expressed as the number
        /// of decimal digits after the second. `nil` leaves it to the handler.
        /// 7-Zip's own presets are 0 (1 s, Unix), 7 (100 ns, Windows) and 9 (1 ns, Linux).
        public var precisionDigits: Int?
        /// `nil` leaves the handler's default; `true`/`false` emit `-mtm=on|off`.
        public var storeModified: Bool?
        /// `-mtc=on|off`.
        public var storeCreated: Bool?
        /// `-mta=on|off`.
        public var storeAccessed: Bool?
        /// Do not disturb the sources' access times while reading them (`-ssp`).
        public var preserveSourceAccessTime: Bool

        public init(
            precisionDigits: Int? = nil,
            storeModified: Bool? = nil,
            storeCreated: Bool? = nil,
            storeAccessed: Bool? = nil,
            preserveSourceAccessTime: Bool = false
        ) {
            self.precisionDigits = precisionDigits
            self.storeModified = storeModified
            self.storeCreated = storeCreated
            self.storeAccessed = storeAccessed
            self.preserveSourceAccessTime = preserveSourceAccessTime
        }
    }
}

/// Ask an engine to remove members from an existing archive.
public struct DeleteRequest: Sendable, Hashable {
    public var archiveURL: URL
    /// Archive-relative paths to remove. Must not be empty — an empty list would
    /// mean "delete everything", which is never what a UI meant to ask for.
    public var entryPaths: [String]
    public var password: String?
    public var formatOverride: ArchiveFormat?

    public init(
        archiveURL: URL,
        entryPaths: [String],
        password: String? = nil,
        formatOverride: ArchiveFormat? = nil
    ) {
        self.archiveURL = archiveURL
        self.entryPaths = entryPaths
        self.password = password
        self.formatOverride = formatOverride
    }
}

/// Ask an engine to rename members in place.
public struct RenameRequest: Sendable, Hashable {
    /// One rename: the member at ``oldPath`` becomes ``newPath``.
    public struct Rename: Sendable, Hashable {
        public var oldPath: String
        public var newPath: String

        public init(oldPath: String, newPath: String) {
            self.oldPath = oldPath
            self.newPath = newPath
        }
    }

    public var archiveURL: URL
    public var renames: [Rename]
    public var password: String?
    public var formatOverride: ArchiveFormat?

    public init(
        archiveURL: URL,
        renames: [Rename],
        password: String? = nil,
        formatOverride: ArchiveFormat? = nil
    ) {
        self.archiveURL = archiveURL
        self.renames = renames
        self.password = password
        self.formatOverride = formatOverride
    }
}

// MARK: - Utility requests

/// Ask an engine to digest files or archive members.
public struct HashRequest: Sendable, Hashable {
    /// What to hash.
    public enum Source: Sendable, Hashable {
        /// Files and directories on disk.
        case files([URL])
        /// Members of an archive, hashed as they decompress.
        case archiveEntries(archiveURL: URL, entryPaths: [String]?)
    }

    public var source: Source
    public var algorithm: HashAlgorithm
    public var password: String?

    public init(source: Source, algorithm: HashAlgorithm = .sha256, password: String? = nil) {
        self.source = source
        self.algorithm = algorithm
        self.password = password
    }
}

/// Ask an engine to run 7-Zip's built-in compression benchmark.
public struct BenchmarkRequest: Sendable, Hashable {
    /// Number of passes. 7-Zip's own default is 1; the Benchmark dialog runs
    /// continuously until stopped.
    public var passes: Int
    /// Dictionary size in bytes, or `nil` for the handler default (24 MiB).
    public var dictionarySize: UInt64?
    /// Threads to use, or `nil` for the machine's hardware thread count.
    public var threads: Int?
    /// Codec to benchmark, or `nil` for the default LZMA mix.
    public var method: CompressionMethod?

    public init(
        passes: Int = 1,
        dictionarySize: UInt64? = nil,
        threads: Int? = nil,
        method: CompressionMethod? = nil
    ) {
        self.passes = passes
        self.dictionarySize = dictionarySize
        self.threads = threads
        self.method = method
    }
}
