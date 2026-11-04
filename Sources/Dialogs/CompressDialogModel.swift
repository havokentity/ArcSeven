// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte
//
// The state and the rules behind the Add to Archive dialog.
//
// 7zFM's `CompressDialog.cpp` is roughly two thousand lines of window procedure in
// which the control state, the format rules and the emitted switches are all the same
// code. That is what makes it hard to reason about: `SetLevel2()` writes to combos,
// reads back from combos, and then other handlers read those combos as the model.
//
// Here the model is a plain value: every control's contents and enabled state is a
// pure function of it, and `reconcile()` is the single place where "the user changed
// something, what is still legal?" is answered. The controller's job reduces to
// (1) copy a control's value into the model, (2) `reconcile()`, (3) redraw everything.
// That is exactly the recompute chain of ADD-22 — SetDictionary2 → SetSolidBlockSize →
// SetNumThreads → SetMemoryUsage — with the ordering guaranteed by data flow instead
// of by remembering to call things in the right sequence.
//
// Everything the format catalogue already knows (level masks, method arrays,
// dictionary/word/solid enumerations, thread ceilings) is asked for rather than
// restated: FormatCatalog is the authority, this file is the state machine.

import Foundation
#if canImport(ArchiveCore)   // module-guard
import ArchiveCore
#endif
#if canImport(Support)   // module-guard
import Support
#endif

/// Everything the Add to Archive dialog holds, plus the rules that keep it coherent.
///
/// A value type on purpose. The controller mutates a copy, reconciles it, and then
/// redraws from it, so there is never a moment where two controls disagree about what
/// the format supports.
public struct CompressDialogModel: Sendable, Equatable {
    // MARK: - Stored state

    /// Full path of the archive to write, as typed. Tilde-expanded on OK, not before,
    /// so what the user typed is what the field keeps showing.
    public var archivePath: String

    /// Files and directories to add. Fixed for the lifetime of the dialog.
    public let inputs: [URL]

    /// `true` when the selection is exactly one regular file.
    ///
    /// Gates the single-stream formats (ADD-06): gzip, bzip2 and xz compress one
    /// stream and have no container, so 7-Zip removes them from the format list
    /// entirely unless there is exactly one input file to be that stream.
    public let hasSingleFileInput: Bool

    public var format: ArchiveFormat
    public var level: CompressionLevel

    /// `nil` selects the combo's first entry, which 7-Zip renders `*  <name>` and
    /// treats as "emit no method property at all" (ADD-11).
    public var method: CompressionMethod?

    public var dictionarySize: DictionarySize
    public var wordSize: WordSize
    public var solidBlockSize: SolidBlockSize
    public var threads: ThreadCount
    public var updateMode: UpdateMode
    public var pathMode: CompressPathMode

    public var createSelfExtracting: Bool
    public var deleteSourcesAfterCompression: Bool

    // The macOS metadata group that stands in for the Windows NTFS group
    // (docs/DIVERGENCES.md D-04). See `extraParameterTokens` for what each one
    // actually emits — two of the four have a real `7zz` switch and two do not.
    public var storeSymbolicLinks: Bool
    public var storeHardLinks: Bool
    public var storeExtendedAttributes: Bool
    public var storePOSIXPermissions: Bool

    public var password: String
    public var verifyPassword: String
    public var showPassword: Bool
    public var encryptFileNames: Bool
    public var encryptionMethod: ArchiveEncryptionMethod

    /// Raw text of the "Split to volumes, bytes" combo. Parsed, never pre-digested,
    /// because the grammar accepts things a number formatter would reject (`650M - CD`).
    public var volumeText: String

    /// Raw text of the Parameters field.
    public var parametersText: String

    /// Windows PE self-extractor stub to prepend. `nil` on a stock install: no stub
    /// ships in the bundle (D-07), so the checkbox is honest about producing nothing.
    public var selfExtractingModuleURL: URL?

    /// The machine's core layout, injected so the thread rules can be exercised without
    /// a machine. `ThreadPlanner` turns it into the automatic thread count (ADD-17).
    public let topology: CPUTopology

    /// Logical CPUs — `topology.logicalCoreCount`, kept as its own field because the
    /// thread combo's ceiling and the `/ N` hint are stated in those terms.
    public let hardwareThreads: Int

    // MARK: - Construction

    public init(
        defaultArchiveURL: URL,
        inputs: [URL],
        topology: CPUTopology = ThreadPlanner.topology
    ) {
        self.archivePath = defaultArchiveURL.path
        self.inputs = inputs
        self.topology = topology
        self.hardwareThreads = max(1, topology.logicalCoreCount)

        // One regular file, not a directory and not a bundle we would descend into.
        if inputs.count == 1,
           let values = try? inputs[0].resourceValues(forKeys: [.isDirectoryKey]) {
            hasSingleFileInput = (values.isDirectory == false)
        } else {
            hasSingleFileInput = false
        }

        // The extension is a hint at the intended format, exactly as ADD-04 treats a
        // typed path. `.tar.gz` resolves to gzip via the last component only, which is
        // what 7-Zip does too — the compound targets are separate picker entries.
        let guess = FormatCatalog.format(forPathExtension: defaultArchiveURL.pathExtension)
        let initial = guess.flatMap { FormatCatalog.canCreate($0) ? $0 : nil } ?? .sevenZip
        self.format = initial

        let descriptor = FormatCatalog.creatable(initial)
        self.level = descriptor?.defaultLevel ?? .normal
        self.method = nil
        self.dictionarySize = .automatic
        self.wordSize = .automatic
        self.solidBlockSize = .automatic
        self.threads = .automatic
        self.updateMode = .addAndReplace
        self.pathMode = .relative
        self.createSelfExtracting = false
        self.deleteSourcesAfterCompression = false
        self.storeSymbolicLinks = true
        self.storeHardLinks = false
        self.storeExtendedAttributes = false
        self.storePOSIXPermissions = false
        self.password = ""
        self.verifyPassword = ""
        self.showPassword = false
        // 7-Zip defaults `Encrypt file names` on for .7z; without it the archive is a
        // published table of contents that happens to have unreadable payloads.
        self.encryptFileNames = true
        self.encryptionMethod = descriptor?.encryptionMethods.first ?? .aes256
        self.volumeText = ""
        self.parametersText = ""
        self.selfExtractingModuleURL = nil

        reconcile()
    }

    // MARK: - Derived facts

    /// The catalogue entry for the selected format, or `nil` if it is not creatable.
    public var descriptor: FormatCatalog.CreatableFormat? {
        FormatCatalog.creatable(format)
    }

    /// Formats the picker offers for this selection.
    ///
    /// The currently selected format is always kept in the list even if it would be
    /// filtered out, so a programmatic selection can never leave the popup blank.
    public var availableFormats: [ArchiveFormat] {
        FormatCatalog.creatableFormats.filter { candidate in
            guard let entry = FormatCatalog.creatable(candidate) else { return false }
            return !entry.keepsName || hasSingleFileInput || candidate == format
        }
    }

    /// Methods the method popup offers, after SFX filtering.
    public var methodChoices: [CompressionMethod] {
        guard let descriptor else { return [] }
        // Store clears the method, dictionary and word-size combos for every format
        // except tar, whose "methods" are dialects rather than codecs (ADD-12).
        if level.rawValue == 0 && format != .tar { return [] }
        guard createSelfExtracting else { return descriptor.methods }
        return descriptor.methods.filter { Self.selfExtractorMethods.contains($0) }
    }

    public var levelChoices: [CompressionLevel] { descriptor?.levels ?? [] }

    public var dictionaryChoices: [UInt64] {
        FormatCatalog.dictionarySizes(format: format, method: method, level: level)
    }

    public var wordSizeChoices: [Int] {
        FormatCatalog.wordSizes(format: format, method: method, level: level)
    }

    public var solidChoices: [SolidBlockSize] {
        FormatCatalog.solidBlockOptions(format: format, level: level)
    }

    /// Explicit thread counts offered, `1 ... min(hwThreads * 2, codecMax)`.
    ///
    /// The doubling is 7-Zip's: hyper-threaded and heterogeneous machines can profit
    /// from oversubscribing a codec that blocks on I/O. When both bounds collapse to
    /// one the numeric list is dropped and only the automatic entry remains (ADD-17).
    public var threadChoices: [Int] {
        guard let descriptor, descriptor.supportsMultithreading else { return [] }
        let ceiling = selectableThreadCeiling
        guard ceiling > 1 else { return [] }
        return Array(1...ceiling)
    }

    public var updateModeChoices: [UpdateMode] { FormatCatalog.updateModes(format: format) }

    /// The dictionary size that will actually be used, resolving the automatic entry.
    public var effectiveDictionaryBytes: UInt64? {
        dictionarySize.byteValue
            ?? FormatCatalog.automaticDictionarySize(format: format, method: method, level: level)
    }

    /// The word size / PPMd model order that will actually be used.
    public var effectiveWordSize: Int? {
        wordSize.intValue
            ?? FormatCatalog.automaticWordSize(format: format, method: method, level: level)
    }

    /// The thread count that will actually be used.
    public var effectiveThreads: Int {
        threads.intValue ?? automaticThreadCount
    }

    /// The method that will actually run, resolving the `*` entry to the format default.
    public var effectiveMethod: CompressionMethod? {
        method ?? descriptor?.defaultMethod
    }

    // MARK: - Control availability

    /// Which controls are live for the current state.
    ///
    /// 7zFM disables rather than hides (except for the NTFS group and `Encrypt file
    /// names`), and so do we: a control that vanishes as you change format makes the
    /// dialog jump, and the user loses track of where things were.
    public struct Availability: Sendable, Equatable {
        public var levelEnabled = false
        public var methodEnabled = false
        public var dictionaryEnabled = false
        public var wordSizeEnabled = false
        public var solidEnabled = false
        public var threadsEnabled = false
        public var updateModeEnabled = false
        public var pathModeEnabled = true
        public var selfExtractingEnabled = false
        public var encryptionEnabled = false
        /// `Encrypt file names` is *shown*, not merely enabled, only for `.7z` (ADD-31).
        public var encryptFileNamesShown = false
        public var symbolicLinksEnabled = false
        public var hardLinksEnabled = false
        public var extendedAttributesEnabled = false
        public var posixPermissionsEnabled = false
        public var volumesEnabled = true
    }

    public var availability: Availability {
        var result = Availability()
        guard let descriptor else { return result }

        result.levelEnabled = descriptor.levels.count > 1
        result.methodEnabled = methodChoices.count > 1
        result.dictionaryEnabled = dictionaryChoices.count > 1
        result.wordSizeEnabled = !wordSizeChoices.isEmpty
        result.solidEnabled = !solidChoices.isEmpty
        result.threadsEnabled = !threadChoices.isEmpty
        result.updateModeEnabled = updateModeChoices.count > 1

        // SFX needs a container that can carry a stub and a codec the stub can decode
        // (ADD-28). `nil` means the format's first method, which for .7z is LZMA2 and
        // therefore allowed.
        result.selfExtractingEnabled = descriptor.supportsSFX
            && (effectiveMethod.map { Self.selfExtractorMethods.contains($0) } ?? true)

        result.encryptionEnabled = descriptor.supportsEncryption
        result.encryptFileNamesShown = descriptor.supportsEncryptedFileNames

        result.symbolicLinksEnabled = descriptor.supportsSymbolicLinks
        result.hardLinksEnabled = Self.hardLinkFormats.contains(format)
        result.extendedAttributesEnabled = Self.perEntryMetadataFormats.contains(format)
        result.posixPermissionsEnabled = Self.perEntryMetadataFormats.contains(format)

        return result
    }

    // MARK: - Reconciliation

    /// Force every dependent field back into a legal combination.
    ///
    /// Called after *any* mutation. Idempotent, and deliberately ordered the way the
    /// dependencies run: format decides the method list, method decides the dictionary
    /// and word lists, method plus format decide the thread ceiling.
    public mutating func reconcile() {
        let formats = availableFormats
        if !formats.contains(format) {
            format = formats.first ?? .sevenZip
        }
        guard let descriptor else { return }

        // The order below IS the dependency order; each step reads what the one above it
        // settled. Splitting it up does not reorder anything.
        reconcileLevel(with: descriptor)
        reconcileMethodAndSFX(with: descriptor)
        reconcileDictionaryAndWordSize()
        reconcileSolidBlockSize()
        reconcileThreads(with: descriptor)

        if !updateModeChoices.contains(updateMode) { updateMode = .addAndReplace }

        reconcileEncryption(with: descriptor)

        // `Encrypt file names` and the four macOS metadata switches are deliberately
        // *not* cleared when the format cannot honour them. They are preferences, and a
        // detour through gzip on the way to picking tar must not silently turn off
        // "Store symbolic links" for good. The controls disable and keep showing the
        // stored choice; `makeRequest` and `extraParameterTokens` mask each one against
        // `availability`, so nothing unsupported can reach the command line.
    }

    /// 7-Zip's `SetNearestSelectComboBox` picks the highest offered value not greater
    /// than the desired one, so switching 7z(9) → gzip lands on gzip's 9 and 7z(4) →
    /// bzip2 lands on 3, never on "nothing selected".
    private mutating func reconcileLevel(with descriptor: FormatCatalog.CreatableFormat) {
        guard !descriptor.levels.contains(level) else { return }
        level = descriptor.levels.last(where: { $0 <= level })
            ?? descriptor.levels.first
            ?? .store
    }

    /// SFX before method: checking it re-filters the method combo, and a method the stub
    /// cannot decode has to be dropped before we validate the selection.
    private mutating func reconcileMethodAndSFX(with descriptor: FormatCatalog.CreatableFormat) {
        if !descriptor.supportsSFX {
            createSelfExtracting = false
        }
        let methods = methodChoices
        if let current = method, !methods.contains(current) {
            method = nil
        }
        if methods.isEmpty {
            method = nil
        }
        if createSelfExtracting,
           let resolved = effectiveMethod,
           !Self.selfExtractorMethods.contains(resolved) {
            createSelfExtracting = false
        }
    }

    /// Dictionary and word size follow the resolved method.
    private mutating func reconcileDictionaryAndWordSize() {
        let dictionaries = dictionaryChoices
        if let bytes = dictionarySize.byteValue, !dictionaries.contains(bytes) {
            dictionarySize = .automatic
        }
        if dictionaries.isEmpty { dictionarySize = .automatic }

        let words = wordSizeChoices
        if let value = wordSize.intValue, !words.contains(value) {
            wordSize = .automatic
        }
        if words.isEmpty { wordSize = .automatic }
    }

    private mutating func reconcileSolidBlockSize() {
        let solids = solidChoices
        if solids.isEmpty {
            solidBlockSize = .automatic
        } else if !solids.contains(solidBlockSize) {
            solidBlockSize = .automatic
        }
    }

    /// An explicit thread count survives a format change only if the new codec can still
    /// use it; otherwise fall back to automatic rather than silently clamping, because a
    /// clamped number looks like the user's choice and is not.
    private mutating func reconcileThreads(with descriptor: FormatCatalog.CreatableFormat) {
        let ceiling = selectableThreadCeiling
        if let count = threads.intValue, count < 1 || count > ceiling {
            threads = .automatic
        }
        if !descriptor.supportsMultithreading { threads = .automatic }
    }

    /// Clearing the password when the format cannot encrypt is what stops a hidden
    /// passphrase from reappearing on a later switch back to .7z.
    private mutating func reconcileEncryption(with descriptor: FormatCatalog.CreatableFormat) {
        if !descriptor.supportsEncryption {
            password = ""
            verifyPassword = ""
        }
        if !descriptor.encryptionMethods.contains(encryptionMethod) {
            encryptionMethod = descriptor.encryptionMethods.first ?? .aes256
        }
    }

    /// Select a format and rewrite the archive's extension to match (ADD-09).
    public mutating func applyFormat(_ newFormat: ArchiveFormat) {
        guard newFormat != format else { return }
        format = newFormat
        reconcile()
        archivePath = Self.rewritingExtension(of: archivePath, for: self)
    }

    /// Toggle the SFX checkbox, with the `.exe` rewrite it implies.
    public mutating func setSelfExtracting(_ enabled: Bool) {
        createSelfExtracting = enabled
        reconcile()
        archivePath = Self.rewritingExtension(of: archivePath, for: self)
    }

    /// Adopt the format implied by a path the user typed, if any (ADD-04).
    ///
    /// Only switches when the extension names a *creatable* format that is currently
    /// offered — typing `.rar` must not select a format we are forbidden to write.
    public mutating func adoptFormatFromArchivePath() {
        let ext = (archivePath as NSString).pathExtension
        guard let guess = FormatCatalog.format(forPathExtension: ext),
              guess != format,
              availableFormats.contains(guess)
        else { return }
        format = guess
        reconcile()
    }

    /// The archive path with its extension replaced to suit the current format.
    ///
    /// Single-stream formats keep the whole original name and append (`report.pdf` →
    /// `report.pdf.gz`); container formats replace (`report.pdf` → `report.7z`).
    /// SFX forces `.exe` regardless.
    private static func rewritingExtension(of path: String, for model: Self) -> String {
        guard !path.isEmpty, let descriptor = model.descriptor else { return path }
        let nsPath = path as NSString
        let directory = nsPath.deletingLastPathComponent
        var name = nsPath.lastPathComponent
        guard !name.isEmpty else { return path }

        let target = model.createSelfExtracting ? "exe" : descriptor.mainExtension
        let current = (name as NSString).pathExtension.lowercased()

        // Recognise any registered archive extension as replaceable; anything else is
        // part of the user's chosen name and is kept.
        let replaceable = !current.isEmpty && FormatCatalog.format(forPathExtension: current) != nil

        if descriptor.keepsName && !model.createSelfExtracting {
            if replaceable { name = (name as NSString).deletingPathExtension }
            name += "." + target
        } else {
            if replaceable { name = (name as NSString).deletingPathExtension }
            name += "." + target
        }
        return directory.isEmpty ? name : (directory as NSString).appendingPathComponent(name)
    }
}

// MARK: - Format traits that the catalogue does not carry

extension CompressDialogModel {
    /// Codecs a 7-Zip self-extractor stub can decode (ADD-28).
    private static let selfExtractorMethods: Set<CompressionMethod> = [.copy, .lzma, .lzma2, .ppmd]

    /// Formats with somewhere to record a hard link.
    ///
    /// Windows shows `Store hard links` for 7z, tar and wim (ADO-02); zip, gzip, bzip2
    /// and xz have no field for it, so the checkbox is dead there on any platform.
    private static let hardLinkFormats: Set<ArchiveFormat> = [.sevenZip, .tar, .wim]

    /// Formats with a per-entry attribute area that macOS metadata can ride in.
    ///
    /// This is where D-04's substitution shows: Windows gates `Store alternate data
    /// streams` on wim alone and `Store file security` on 7z and wim, because those are
    /// the two handlers with NTFS-shaped slots. The macOS analogues — xattrs and the
    /// POSIX mode/owner triple — live in the ordinary per-entry attribute word that 7z,
    /// tar and wim all carry, so the gate moves with the concept rather than being
    /// transcribed from the Windows handler flags. zip/gzip/bzip2/xz stay out for the
    /// same reason they do on Windows: nowhere to put it.
    private static let perEntryMetadataFormats: Set<ArchiveFormat> = [.sevenZip, .tar, .wim]

    // MARK: - Volume size grammar

    /// 7-Zip's `Split to volumes, bytes` grammar (ADD-25).
    ///
    /// Deliberately not a `NumberFormatter`: the accepted text includes the combo's own
    /// preset labels, and `650M - CD` has to parse as a single 650 MiB volume because
    /// the hyphen terminates the sequence *successfully* rather than being an error.
    public enum VolumeSizeGrammar {
        /// The preset list, verbatim, including the descriptive tails that the grammar
        /// swallows. The capacities are the conservative ones 7-Zip ships — 4092 MiB
        /// for FAT32 rather than the theoretical 4096, 4480 for a single-layer DVD.
        public static let presets: [String] = [
            "10M",
            "100M",
            "1000M",
            "650M - CD",
            "700M - CD",
            "4092M - FAT",
            "4480M - DVD",
            "8128M - DVD DL",
            "23040M - BD",
        ]

        /// Sizes below which 7-Zip asks the user to confirm (ADD-26).
        public static let tinyVolumeThreshold: UInt64 = 100 << 10

        /// Parse a whitespace-separated sequence of sizes.
        ///
        /// Suffixes are `b`, `k`, `m`, `g`, `t`, case-insensitive and binary (1 k =
        /// 1024). A bare number is bytes. Anything after the suffix inside a token is
        /// ignored. An empty string means "do not split", which is not an error.
        ///
        /// - Throws: ``ValidationFailure/incorrectVolumeSize`` on a zero, a
        ///   non-numeric token, an unknown suffix, or an overflowing multiplication.
        public static func parse(_ text: String) throws -> [UInt64] {
            var sizes: [UInt64] = []

            for token in text.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                // A hyphen ends the sequence and everything already parsed stands. This
                // is what makes the preset labels legal input rather than a special case.
                if token.hasPrefix("-") { break }

                let characters = Array(token)
                var index = 0
                while index < characters.count, characters[index].isASCII, characters[index].isNumber {
                    index += 1
                }
                guard index > 0, let value = UInt64(String(characters[0..<index])) else {
                    throw ValidationFailure.incorrectVolumeSize
                }

                var multiplier: UInt64 = 1
                if index < characters.count {
                    switch characters[index] {
                    case "b", "B": multiplier = 1
                    case "k", "K": multiplier = 1 << 10
                    case "m", "M": multiplier = 1 << 20
                    case "g", "G": multiplier = 1 << 30
                    case "t", "T": multiplier = 1 << 40
                    default: throw ValidationFailure.incorrectVolumeSize
                    }
                }

                let (bytes, overflowed) = value.multipliedReportingOverflow(by: multiplier)
                guard !overflowed, bytes > 0 else { throw ValidationFailure.incorrectVolumeSize }
                sizes.append(bytes)
            }

            return sizes
        }
    }
}

// MARK: - Memory estimate

extension CompressDialogModel {
    /// What the read-only "Memory usage" rows show.
    public struct MemoryEstimate: Sendable, Equatable {
        /// Bytes the encoder is expected to need, or `nil` when it cannot be guessed.
        public var compressing: UInt64?
        /// Bytes a decoder will need to read the result back.
        public var decompressing: UInt64?
    }

    /// A **documented approximation** of the encoder's peak resident set.
    ///
    /// This is not 7-Zip's `GetMemoryUsage()`. That function is a long chain of exact
    /// terms — the LZMA hash-size computation, the block-size inflation
    /// `blockSize += blockSize >> (blockSize < 1 GB ? 1 : 2)` capped at `0xFFFF0000`,
    /// the chunked path with its three thread-count bumps, the BCJ2 allowance at level
    /// ≥ 9 — and reproducing it faithfully is a job for `ArchiveCore.MemoryEstimator`
    /// (docs/FIDELITY.md ADD-21), where it can be unit-tested against the real numbers.
    ///
    /// What this gives instead is the well-known per-codec rules of thumb, which land
    /// within roughly ±20% of 7-Zip's own figure for the common cases:
    ///
    /// * LZMA/LZMA2 encode ≈ 11.5 × dictionary + 6 MB per encoder instance. The 11.5
    ///   comes from the match finder: BT4 keeps a hash chain and a binary tree over the
    ///   window, which is ~10.5 × the window plus the window itself.
    /// * LZMA2 hands each *block* its own encoder, and at level ≥ 5 each encoder is
    ///   itself two-threaded, so the number of concurrent encoders is threads / 2.
    /// * PPMd is a flat model allocation: the "dictionary" size *is* the model, and the
    ///   decoder needs exactly as much as the encoder — which is why PPMd archives can
    ///   be undecodable on a smaller machine.
    /// * BZip2 ≈ 10 MB per thread to compress, 7 MB to decompress, independent of the
    ///   block size knob.
    /// * Deflate ≈ 4 MB per thread; its 32 KB window makes decoding free.
    /// * zip additionally buffers ~64 MB per worker in the container layer, which
    ///   dominates everything else once the thread count is high. That term is 7-Zip's
    ///   `numMainZipThreads * (sizeof(size_t) << 23)` with `sizeof(size_t) = 8`.
    ///
    /// Treat the result as an order-of-magnitude guide, and never as a promise.
    public func estimateMemory() -> MemoryEstimate {
        let mib: UInt64 = 1 << 20
        guard descriptor != nil else { return MemoryEstimate(compressing: nil, decompressing: nil) }

        // Store copies bytes; the only memory involved is the I/O buffer.
        if level.rawValue == 0 && format != .tar {
            return MemoryEstimate(compressing: 1 * mib, decompressing: 1 * mib)
        }

        let threadCount = UInt64(max(1, effectiveThreads))
        let dictionary = effectiveDictionaryBytes ?? 0

        var compressing: UInt64
        var decompressing: UInt64

        switch effectiveMethod {
        case .lzma2:
            let perEncoder = UInt64(Double(dictionary) * 11.5) + 6 * mib
            // At level ≥ 5 LZMA2 runs a two-thread encoder per block, so a 16-thread
            // job is 8 concurrent dictionaries, not 16. Getting this wrong is the usual
            // reason a memory read-out is off by 2×.
            let threadsPerBlock: UInt64 = level.rawValue >= 5 ? 2 : 1
            let blocks = max(1, threadCount / threadsPerBlock)
            compressing = perEncoder * blocks + 2 * mib
            decompressing = dictionary + 2 * mib

        case .lzma:
            // Single-stream LZMA: the second thread is the match finder and shares the
            // window, so the count does not multiply the footprint.
            compressing = UInt64(Double(dictionary) * 11.5) + 6 * mib
            decompressing = dictionary + 2 * mib

        case .ppmd:
            compressing = dictionary + 2 * mib
            decompressing = dictionary + 2 * mib

        case .bzip2:
            compressing = 10 * mib * threadCount
            decompressing = 7 * mib

        case .deflate, .deflate64:
            compressing = 4 * mib * threadCount
            decompressing = 1 * mib

        case .copy, .gnuTar, .posixTar, .none:
            compressing = 1 * mib
            decompressing = 1 * mib
        }

        if format == .zip {
            compressing += threadCount * (8 << 23)
        }

        // 7z applies a BCJ/BCJ2 branch filter automatically at Ultra, and BCJ2 keeps
        // four streams in flight (ADD-21's `12 MB * 2 + 5 MB`).
        if format == .sevenZip && level.rawValue >= 9 {
            compressing += 29 * mib
        }

        return MemoryEstimate(compressing: compressing, decompressing: decompressing)
    }
}

// MARK: - Validation

extension CompressDialogModel {
    /// Why OK cannot proceed. Messages are 7-Zip's own, verbatim (ADD-38).
    public enum ValidationFailure: Error, LocalizedError, Equatable, Sendable {
        case incorrectArchivePath
        case incorrectVolumeSize
        case passwordsDoNotMatch
        case nonASCIIZipPassword
        case zipPasswordTooLong

        public var errorDescription: String? {
            switch self {
            case .incorrectArchivePath:
                "Incorrect archive path"
            case .incorrectVolumeSize:
                "Incorrect volume size"
            case .passwordsDoNotMatch:
                "Passwords do not match"
            case .nonASCIIZipPassword:
                "Use only English letters, numbers and special characters (!, #, $, ...) for password."
            case .zipPasswordTooLong:
                "Password is too long"
            }
        }
    }

    /// Whether extended attributes will really be stored.
    ///
    /// `CompressRequest` has no field for this, so a caller reads the flag off the
    /// model — and needs it masked the same way the request's own fields are.
    public var storesExtendedAttributes: Bool {
        storeExtendedAttributes && availability.extendedAttributesEnabled
    }

    /// `true` when the encryption group is live and the user has actually typed a
    /// passphrase. An empty passphrase means "no encryption", exactly as in 7-Zip
    /// (ADD-34) — it never means "encrypt with nothing".
    public var isEncryptionRequested: Bool {
        availability.encryptionEnabled && !password.isEmpty
    }

    /// The volume-size error to show inline under the combo, or `nil` when it parses.
    public var volumeSizeError: ValidationFailure? {
        do {
            _ = try VolumeSizeGrammar.parse(volumeText)
            return nil
        } catch let failure as ValidationFailure {
            return failure
        } catch {
            return .incorrectVolumeSize
        }
    }

    /// The password error to show inline, or `nil`.
    public var passwordError: ValidationFailure? {
        guard isEncryptionRequested else { return nil }

        // ADD-38 runs the checks in this order, and the order is visible to the user:
        // a zip password that is both non-ASCII and mistyped complains about the
        // characters first, because that is the problem the retype cannot fix.
        if format == .zip {
            // zip stores the passphrase bytes with no encoding marker, so anything
            // outside printable ASCII decodes differently in another tool. 7-Zip
            // refuses rather than producing an archive only it can open.
            let isPrintableASCII: (Character) -> Bool = { character in
                guard let byte = character.asciiValue else { return false }
                return byte >= 0x20 && byte <= 0x7F
            }
            if password.contains(where: { !isPrintableASCII($0) }) { return .nonASCIIZipPassword }
            if encryptionMethod == .aes256 && password.count > 99 { return .zipPasswordTooLong }
        }

        // Show Password removes the second field, and with it the match requirement
        // (ADD-33) — there is nothing to mistype when the passphrase is legible.
        if !showPassword && password != verifyPassword { return .passwordsDoNotMatch }
        return nil
    }

    /// Run 7-Zip's OK-time checks in its order (ADD-38 steps 1–7).
    public func validate() throws {
        if let failure = passwordError { throw failure }
        guard !archivePath.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ValidationFailure.incorrectArchivePath
        }
        _ = try VolumeSizeGrammar.parse(volumeText)
    }
}

// MARK: - Emission

extension CompressDialogModel {
    /// Extra `7zz` switches beyond what `CompressRequest`'s structured fields cover.
    ///
    /// Two sources, in 7-Zip's precedence order — the macOS metadata switches first,
    /// then the Parameters field, so a user override wins (ADD-35).
    public var extraParameterTokens: [String] {
        var tokens: [String] = []

        // "Store POSIX permissions" → `-snoi`, which records uid/gid alongside the mode
        // bits. The mode itself always goes into the entry's attribute word whether we
        // ask or not; ownership is the part that is genuinely optional, and the part a
        // user restoring onto a different machine may not want.
        if storePOSIXPermissions && availability.posixPermissionsEnabled {
            tokens.append("-snoi")
        }

        // "Store extended attributes" has no `7zz` switch. macOS xattrs and resource
        // forks are captured by ArcSeven's own engine (D-17), not by the console tool,
        // so nothing is emitted here — inventing a switch would make the whole
        // operation fail with a command-line error instead of quietly doing less.
        // The flag stays readable on the model for the engine layer to honour.

        for token in parametersText.split(whereSeparator: { $0.isWhitespace }) {
            let text = String(token)
            // ADD-35: a bare `x=9` is shorthand for `-mx=9`. Anything already carrying a
            // leading dash is passed through untouched, switches included.
            tokens.append(text.hasPrefix("-") ? text : "-m" + text)
        }

        return tokens
    }

    /// Build the request, or throw the first ADD-38 failure.
    public func makeRequest() throws -> CompressRequest {
        try validate()

        let trimmed = archivePath.trimmingCharacters(in: .whitespaces)
        let url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)

        var request = CompressRequest(archiveURL: url, inputs: inputs, format: format)
        request.level = level
        request.method = method
        request.dictionarySize = dictionarySize
        request.wordSize = wordSize
        request.solidBlockSize = solidBlockSize
        request.threads = requestedThreads
        request.updateMode = updateMode
        request.pathMode = pathMode
        request.volumeSizes = try VolumeSizeGrammar.parse(volumeText)
        request.extraParameters = extraParameterTokens
        request.deleteSourcesAfterCompression = deleteSourcesAfterCompression
        request.storeSymbolicLinks = storeSymbolicLinks && availability.symbolicLinksEnabled
        request.storeHardLinks = storeHardLinks && availability.hardLinksEnabled

        if isEncryptionRequested {
            request.encryption = CompressRequest.EncryptionOptions(
                password: password,
                encryptFileNames: encryptFileNames && availability.encryptFileNamesShown,
                method: encryptionMethod
            )
        }

        if createSelfExtracting {
            request.selfExtractingModuleURL = selfExtractingModuleURL
        }

        return request
    }

    // MARK: - Rendering helpers

    /// Dictionary-size text, in 7-Zip's units.
    ///
    /// There is deliberately **no GB unit** here: 7-Zip renders a 1 GiB dictionary as
    /// `1024 MB` (ADD-14), and matching that matters because the numbers are how users
    /// compare settings against advice written for the Windows build.
    public static func dictionaryLabel(_ bytes: UInt64) -> String {
        if bytes < (1 << 20) { return "\(bytes >> 10) KB" }
        return "\(bytes >> 20) MB"
    }

    /// Solid-block-size text, which *does* get a GB unit (ADD-16).
    public static func solidLabel(_ size: SolidBlockSize) -> String {
        switch size {
        case .automatic: "*"
        case .nonSolid:  "Non-solid"
        case .fullySolid: "Solid"
        case .bytes(let bytes):
            bytes >= (1 << 30) ? "\(bytes >> 30) GB" : "\(bytes >> 20) MB"
        }
    }

    /// Memory read-out text. Rounds **up** and steps MB → GB → TB (ADD-20).
    public static func memoryLabel(_ bytes: UInt64?) -> String {
        guard let bytes else { return "?" }
        let mib: UInt64 = 1 << 20
        let gib: UInt64 = 1 << 30
        let tib: UInt64 = 1 << 40
        if bytes <= 16 * gib { return "\((bytes + mib - 1) / mib) MB" }
        if bytes <= 64 * tib { return "\((bytes + gib - 1) / gib) GB" }
        return "\((bytes + tib - 1) / tib) TB"
    }
}
