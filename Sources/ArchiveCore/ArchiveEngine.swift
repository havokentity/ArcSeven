// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte

import Foundation

// MARK: - Operations

/// The kind of work an engine is doing. Used to label progress UI and to tell
/// events from different operations apart in a log.
public enum ArchiveOperation: String, Sendable, Hashable, Codable, CaseIterable {
    case list
    case extract
    case test
    case compress
    case delete
    case rename
    case hash
    case benchmark
    case readEntry

    /// `true` when the operation writes to the archive. Write operations must not
    /// run concurrently against the same archive.
    public var mutatesArchive: Bool {
        switch self {
        case .compress, .delete, .rename: true
        case .list, .extract, .test, .hash, .benchmark, .readEntry: false
        }
    }
}

// MARK: - Progress

/// A progress sample.
///
/// The CLI engine's raw resolution is **integer percent plus a file counter** — no
/// byte counts, no ETA (res_3 §4a.5). ``processedByteCount`` and
/// ``totalByteCount`` are therefore *interpolated*: the engine reads the true total
/// from a pre-flight `l -slt` and multiplies by the percent tick. A future
/// in-process engine gets real byte callbacks from `IArchiveExtractCallback::SetCompleted`
/// and fills the same fields exactly. Consumers must not care which they got, but
/// they must honour ``isByteCountExact`` before showing a byte-precise readout.
public struct ArchiveProgress: Sendable, Hashable {
    /// What the engine is doing right now.
    public enum Phase: String, Sendable, Hashable, Codable {
        /// Walking the input selection before any compression starts. `7zz` reports
        /// this as a `<n>M Scan` token.
        case scanning
        /// Reading, writing or verifying member data.
        case processing
        /// Writing out the archive header / finalising.
        case finalising
    }

    public var phase: Phase

    /// Completed fraction in `0...1`, or `nil` when the engine has not reported one
    /// yet.
    ///
    /// - Important: **Never treat `1.0` as completion.** `7zz` emits `100%` well
    ///   before it finishes writing headers, and small jobs emit exactly one tick
    ///   (`0%`) and nothing else. Completion is ``ArchiveEvent/finished(_:)``, full
    ///   stop (res_3 §4a.5).
    public var fractionCompleted: Double?

    /// Members finished so far, as the engine counts them.
    public var processedItemCount: Int?

    /// Total members, when a pre-flight listing or scan established one.
    public var totalItemCount: Int?

    /// Bytes processed so far.
    public var processedByteCount: UInt64?

    /// Total bytes expected.
    public var totalByteCount: UInt64?

    /// `false` when the byte counts were interpolated from a percentage rather than
    /// measured. The CLI engine always sets `false`.
    public var isByteCountExact: Bool

    /// The member currently being worked on, when the engine names one.
    public var currentItemPath: String?

    public init(
        phase: Phase = .processing,
        fractionCompleted: Double? = nil,
        processedItemCount: Int? = nil,
        totalItemCount: Int? = nil,
        processedByteCount: UInt64? = nil,
        totalByteCount: UInt64? = nil,
        isByteCountExact: Bool = false,
        currentItemPath: String? = nil
    ) {
        self.phase = phase
        self.fractionCompleted = fractionCompleted
        self.processedItemCount = processedItemCount
        self.totalItemCount = totalItemCount
        self.processedByteCount = processedByteCount
        self.totalByteCount = totalByteCount
        self.isByteCountExact = isByteCountExact
        self.currentItemPath = currentItemPath
    }
}

/// A member the engine has finished handling.
public struct ArchiveItemEvent: Sendable, Hashable {
    /// What happened to the member.
    public enum Action: String, Sendable, Hashable, Codable {
        case added
        case extracted
        case updated
        case deleted
        case tested
        case skipped
        /// The engine used a marker we do not recognise; ``rawMarker`` has it.
        case unknown
    }

    public var action: Action
    /// Archive-relative path.
    public var path: String
    /// The single-character marker `7zz` used (`+`, `-`, `U`, …), preserved so an
    /// unrecognised one is still reportable.
    public var rawMarker: Character?

    public init(action: Action, path: String, rawMarker: Character? = nil) {
        self.action = action
        self.path = path
        self.rawMarker = rawMarker
    }
}

// MARK: - Events

/// Everything an in-flight operation reports.
///
/// The stream is ordered and finishes with exactly one ``finished(_:)`` on success,
/// or throws an ``ArchiveError``. It never both throws and emits `finished`.
public enum ArchiveEvent: Sendable {
    /// The operation has begun. Always the first event.
    case started(ArchiveOperation)
    /// A progress sample. Emitted at whatever cadence the engine produces; the CLI
    /// engine's cadence is throughput-dependent, not periodic (res_3 §4a.5).
    case progress(ArchiveProgress)
    /// A member finished.
    case item(ArchiveItemEvent)
    /// A line of engine output that is neither progress nor a warning: banners,
    /// summaries, `Everything is Ok`. Preserved verbatim for the Diagnostic
    /// Messages window.
    case log(String)
    /// A non-fatal problem. The operation continues.
    case warning(ArchiveWarning)
    /// The operation completed. Always the last event.
    case finished(ArchiveOperationResult)
}

/// The stream type every mutating engine operation returns.
///
/// Cancellation is by the standard Swift mechanism: cancel the task that is
/// consuming the stream, or simply stop iterating it. Engines observe termination
/// and shut their work down — for the CLI engine that means signalling the child's
/// process group and draining its pipes to EOF.
public typealias ArchiveOperationStream = AsyncThrowingStream<ArchiveEvent, any Error>

// MARK: - Results

/// What an operation produced.
public struct ArchiveOperationResult: Sendable {
    /// Extra output specific to certain operations.
    public enum Payload: Sendable {
        /// The operation produced nothing beyond the result itself.
        case empty
        case listing(ArchiveListing)
        case hashes([HashResult])
        case benchmark(BenchmarkResult)
    }

    public var operation: ArchiveOperation

    /// Non-fatal problems.
    ///
    /// A non-empty array here is the normal, expected shape of `7zz` exit code 1:
    /// the work succeeded and something is worth mentioning. It is **not** a
    /// failure and must not be presented as one (res_3 §4a.8).
    public var warnings: [ArchiveWarning]

    /// Members the operation touched.
    public var itemsProcessed: Int

    /// Every log line the engine emitted, in order.
    public var log: [String]

    /// Wall-clock duration.
    public var duration: Duration

    /// Operation-specific output.
    public var payload: Payload

    public init(
        operation: ArchiveOperation,
        warnings: [ArchiveWarning] = [],
        itemsProcessed: Int = 0,
        log: [String] = [],
        duration: Duration = .zero,
        payload: Payload = .empty
    ) {
        self.operation = operation
        self.warnings = warnings
        self.itemsProcessed = itemsProcessed
        self.log = log
        self.duration = duration
        self.payload = payload
    }

    /// `true` when the operation finished with complaints.
    public var hasWarnings: Bool { !warnings.isEmpty }

    /// The listing, when this was a `list`.
    public var listing: ArchiveListing? {
        if case .listing(let listing) = payload { return listing }
        return nil
    }

    /// The digests, when this was a `hash`.
    public var hashes: [HashResult]? {
        if case .hashes(let hashes) = payload { return hashes }
        return nil
    }

    /// The benchmark table, when this was a `benchmark`.
    public var benchmark: BenchmarkResult? {
        if case .benchmark(let benchmark) = payload { return benchmark }
        return nil
    }
}

/// One digest produced by a hash operation.
public struct HashResult: Sendable, Hashable, Codable {
    public var algorithm: HashAlgorithm
    /// The file or member that was hashed. `nil` for the whole-input summary row.
    public var path: String?
    /// Uppercase hexadecimal digest.
    public var digest: String
    /// Size of the data that was hashed, when reported.
    public var size: UInt64?

    public init(algorithm: HashAlgorithm, path: String?, digest: String, size: UInt64? = nil) {
        self.algorithm = algorithm
        self.path = path
        self.digest = digest
        self.size = size
    }
}

/// The output of 7-Zip's built-in benchmark.
public struct BenchmarkResult: Sendable, Hashable, Codable {
    /// One dictionary-size row of the results grid.
    public struct Row: Sendable, Hashable, Codable {
        /// Dictionary size in bytes.
        public var dictionarySize: UInt64
        /// Compression throughput in KiB/s.
        public var compressSpeed: UInt64?
        /// Compression rating in MIPS.
        public var compressRating: UInt64?
        /// Compression CPU utilisation, percent.
        public var compressUsage: Int?
        /// Decompression throughput in KiB/s.
        public var decompressSpeed: UInt64?
        /// Decompression rating in MIPS.
        public var decompressRating: UInt64?
        /// Decompression CPU utilisation, percent.
        public var decompressUsage: Int?

        public init(
            dictionarySize: UInt64,
            compressSpeed: UInt64? = nil,
            compressRating: UInt64? = nil,
            compressUsage: Int? = nil,
            decompressSpeed: UInt64? = nil,
            decompressRating: UInt64? = nil,
            decompressUsage: Int? = nil
        ) {
            self.dictionarySize = dictionarySize
            self.compressSpeed = compressSpeed
            self.compressRating = compressRating
            self.compressUsage = compressUsage
            self.decompressSpeed = decompressSpeed
            self.decompressRating = decompressRating
            self.decompressUsage = decompressUsage
        }
    }

    public var rows: [Row]
    /// The `Tot:` rating in MIPS — the single headline number.
    public var totalRating: UInt64?
    /// The `Avr:` compression rating in MIPS.
    public var averageCompressRating: UInt64?
    /// The `Avr:` decompression rating in MIPS.
    public var averageDecompressRating: UInt64?
    /// Threads the run used.
    public var threads: Int?
    /// CPU description line, when the engine printed one.
    public var cpuDescription: String?

    public init(
        rows: [Row] = [],
        totalRating: UInt64? = nil,
        averageCompressRating: UInt64? = nil,
        averageDecompressRating: UInt64? = nil,
        threads: Int? = nil,
        cpuDescription: String? = nil
    ) {
        self.rows = rows
        self.totalRating = totalRating
        self.averageCompressRating = averageCompressRating
        self.averageDecompressRating = averageDecompressRating
        self.threads = threads
        self.cpuDescription = cpuDescription
    }
}

// MARK: - Errors

/// Diagnostic detail attached to a failure.
public struct ArchiveFailureDetail: Sendable, Hashable, Codable {
    /// The engine's exit status, when there was a process.
    public var exitCode: Int32?
    /// Error lines the engine emitted, verbatim.
    public var messages: [String]
    /// Warnings collected before the failure.
    public var warnings: [ArchiveWarning]
    /// The archive or path the failure is about, when known.
    public var path: String?

    public init(
        exitCode: Int32? = nil,
        messages: [String] = [],
        warnings: [ArchiveWarning] = [],
        path: String? = nil
    ) {
        self.exitCode = exitCode
        self.messages = messages
        self.warnings = warnings
        self.path = path
    }

    /// The engine's own words, joined, or an empty string.
    public var combinedMessage: String {
        messages.joined(separator: "\n")
    }
}

/// What an engine needed from the user but could not ask for.
public enum ArchiveInputRequirement: String, Sendable, Hashable, Codable {
    /// A password. Either the archive's header is encrypted, or a member is.
    case password
    /// An overwrite decision. The caller left ``OverwriteMode/ask`` unresolved.
    case overwriteDecision
    /// The engine prompted for something we could not classify.
    case unknown
}

/// Every way an archive operation can fail.
///
/// The mapping from `7zz` exit statuses to these cases lives in ``ExitCodeMapper``
/// and is the single place that encodes the rule that matters most:
///
/// > **Exit code 1 is not in this enum.** Code 1 means "finished, with warnings" —
/// > the archive was still created, the files were still extracted — and it
/// > surfaces as a successful ``ArchiveOperationResult`` whose ``ArchiveOperationResult/warnings``
/// > is non-empty. An app that reports failure on 1 cries wolf every time a large
/// > selection contains one unreadable file (res_3 §4a.8).
public enum ArchiveError: Error, Sendable, Hashable {
    /// Exit 2. The archive is corrupt, unreadable, or an output could not be written.
    case fatal(ArchiveFailureDetail)

    /// Exit 2 with a wrong-password diagnosis. Split out from ``fatal(_:)`` because
    /// the UI response is completely different: re-prompt, do not report corruption.
    case wrongPassword(ArchiveFailureDetail)

    /// Exit 7. We built a command line the engine rejected. Always a bug in this
    /// app, never the user's fault, and worth logging loudly.
    case commandLine(ArchiveFailureDetail)

    /// Exit 8. The engine could not allocate what the chosen dictionary size needs.
    case outOfMemory(ArchiveFailureDetail)

    /// Exit 255 after we asked the engine to stop. A clean, expected outcome:
    /// `7zz` unwinds and removes the partial archive it was writing (res_3 §4a.9).
    case cancelled

    /// Exit 255 *without* a cancellation request, meaning the engine hit a prompt
    /// and found stdin at EOF.
    ///
    /// This is the overloaded half of 255 and the reason every invocation passes
    /// `-y` and resolves passwords before spawning: with those in place, a 255 we
    /// did not ask for can only be this.
    case inputRequired(ArchiveInputRequirement, ArchiveFailureDetail)

    /// The engine died on a signal rather than exiting.
    case terminatedBySignal(Int32, ArchiveFailureDetail)

    /// An exit status with no defined meaning.
    case unexpectedExitCode(Int32, ArchiveFailureDetail)

    /// The engine binary is missing, unreadable, or not executable.
    case engineUnavailable(String)

    /// The engine could not be launched.
    case launchFailed(String)

    /// The request itself is not something this engine can carry out.
    case invalidRequest(String)

    /// The engine's output did not match the grammar we parse.
    case malformedOutput(String)

    /// A streamed member grew past the byte ceiling the request set.
    ///
    /// Raised by ``ArchiveEngine/readEntry(_:)`` when the member exceeds
    /// ``ReadEntryRequest/maximumByteCount``. The consumer has received at most that
    /// many bytes and must treat them as a truncated prefix, never as the member. The
    /// child is stopped the moment the limit is crossed, so a decompression bomb costs
    /// one pipe buffer, not a disk.
    case outputLimitExceeded(UInt64)

    /// An archive was created with encryption requested, but a post-creation check
    /// found it unencrypted.
    ///
    /// This exists because the failure it guards against is silent: 7-Zip encrypts
    /// only when `-p` is on the command line, and a password fed on stdin during
    /// creation is discarded, producing a plaintext archive with exit code 0 and no
    /// warning at all (res_3 §4a.7).
    case encryptionVerificationFailed(String)

    /// Filesystem trouble outside the engine.
    ///
    /// Named for the concept, not trimmed to fit a length rule: this case is public
    /// API that `FMKit` and `FMUI` already throw, so renaming it would break callers
    /// this module does not own, and `ioError` would only restate the enum's name.
    case io(String) // swiftlint:disable:this identifier_name
}

extension ArchiveError {
    /// The diagnostic detail, when the case carries any.
    public var detail: ArchiveFailureDetail? {
        switch self {
        case .fatal(let detail), .wrongPassword(let detail), .commandLine(let detail),
             .outOfMemory(let detail), .terminatedBySignal(_, let detail),
             .unexpectedExitCode(_, let detail), .inputRequired(_, let detail):
            return detail
        case .cancelled, .engineUnavailable, .launchFailed, .invalidRequest,
             .malformedOutput, .outputLimitExceeded, .encryptionVerificationFailed, .io:
            return nil
        }
    }

    /// `true` when retrying with a password could plausibly succeed.
    public var needsPassword: Bool {
        switch self {
        case .wrongPassword: true
        case .inputRequired(let requirement, _): requirement == .password
        default: false
        }
    }
}

extension ArchiveError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .fatal(let detail):
            return detail.messages.first ?? "The archive could not be processed."
        case .wrongPassword:
            return "The password is incorrect."
        case .commandLine(let detail):
            return "The archive engine rejected the command: \(detail.combinedMessage)"
        case .outOfMemory:
            return "There is not enough memory for the selected compression settings."
        case .cancelled:
            return "The operation was cancelled."
        case .inputRequired(let requirement, _):
            switch requirement {
            case .password:          return "A password is required."
            case .overwriteDecision: return "An overwrite decision is required."
            case .unknown:           return "The archive engine needs input that was not supplied."
            }
        case .terminatedBySignal(let signal, _):
            return "The archive engine stopped unexpectedly (signal \(signal))."
        case .unexpectedExitCode(let code, _):
            return "The archive engine exited with an unexpected status (\(code))."
        case .engineUnavailable(let reason):
            return "The archive engine is unavailable: \(reason)"
        case .launchFailed(let reason):
            return "The archive engine could not be started: \(reason)"
        case .invalidRequest(let reason):
            return "The request is not valid: \(reason)"
        case .malformedOutput(let reason):
            return "The archive engine produced output that could not be understood: \(reason)"
        case .outputLimitExceeded(let limit):
            return "The item is larger than the \(limit)-byte limit for reading it into memory."
        case .encryptionVerificationFailed(let reason):
            return "The archive was not encrypted: \(reason)"
        case .io(let reason):
            return reason
        }
    }
}

// MARK: - Capabilities

/// What a particular engine can do.
///
/// Lets the UI gate affordances without knowing which engine is installed, so the
/// eventual in-process XPC engine — which will ship *without* the RAR handlers for
/// licence reasons — can advertise a smaller format set and have the panes adapt.
public struct EngineCapabilities: Sendable, Hashable {
    /// Formats this engine can write.
    public var creatableFormats: Set<ArchiveFormat>
    /// Formats this engine can read.
    public var readableFormats: Set<ArchiveFormat>
    /// `true` when progress carries measured byte counts rather than interpolated ones.
    public var providesExactByteProgress: Bool
    /// `true` when passwords never leave the app's memory.
    ///
    /// `false` for the CLI engine on the creation path, where 7-Zip requires `-p`
    /// on argv and the passphrase is briefly visible in `ps` (res_3 §4a.7).
    public var keepsPasswordsInProcess: Bool
    /// `true` when the engine can run 7-Zip's benchmark.
    public var supportsBenchmark: Bool
    /// `true` when the engine can compute digests.
    public var supportsHashing: Bool
    /// `true` when a member can be streamed without writing it to disk.
    public var supportsStreamingSingleEntry: Bool
    /// Engine version string, for the About box and for bug reports.
    public var versionDescription: String

    public init(
        creatableFormats: Set<ArchiveFormat> = [],
        readableFormats: Set<ArchiveFormat> = [],
        providesExactByteProgress: Bool = false,
        keepsPasswordsInProcess: Bool = false,
        supportsBenchmark: Bool = false,
        supportsHashing: Bool = false,
        supportsStreamingSingleEntry: Bool = false,
        versionDescription: String = ""
    ) {
        self.creatableFormats = creatableFormats
        self.readableFormats = readableFormats
        self.providesExactByteProgress = providesExactByteProgress
        self.keepsPasswordsInProcess = keepsPasswordsInProcess
        self.supportsBenchmark = supportsBenchmark
        self.supportsHashing = supportsHashing
        self.supportsStreamingSingleEntry = supportsStreamingSingleEntry
        self.versionDescription = versionDescription
    }
}

// MARK: - The protocol

/// The contract every archive back end satisfies.
///
/// Two implementations are planned and the shape of this protocol is chosen so that
/// both fit without contortion:
///
/// - ``SevenZipCLIEngine`` spawns the bundled upstream `7zz` and parses its streams.
///   It is the shipping engine: it gets full format coverage for free, isolates
///   decoder crashes in a child process, and turns a security update into a file swap.
/// - A future in-process XPC engine will drive `7z.dylib` through its COM-style
///   interfaces, gaining real byte-level progress, random access and in-memory
///   passwords. It must be built **without** the RAR handlers so the in-process engine
///   does not import the upstream unRAR use restriction into first-party code.
///
/// ### Concurrency
///
/// Conformers are `Sendable` and every operation is independently cancellable. The
/// stream-returning methods are synchronous and non-isolated: they hand back a cold
/// stream, and work begins when you start iterating. That keeps the protocol usable
/// from any isolation domain and makes it impossible to accidentally start an
/// operation you never consume.
///
/// ### Cancellation
///
/// Cancel the consuming task, or break out of the `for try await` loop. Engines
/// observe stream termination and stop. The CLI engine signals the child's process
/// group, then drains its pipes to EOF and reaps it — `7zz` responds by unwinding
/// cleanly and deleting the partial archive it was writing (res_3 §4a.9). Note the
/// asymmetry: a cancelled *extraction* leaves already-written files on disk, and it
/// is the caller's job to clean the destination up.
///
/// ### Error policy
///
/// Throwing means the operation did not achieve its goal. Finishing with a
/// non-empty ``ArchiveOperationResult/warnings`` means it did, imperfectly. Nothing
/// in this protocol converts a warning into a failure.
public protocol ArchiveEngine: Sendable {
    /// Stable identifier for logs and preferences, e.g. `"7zz-cli"`.
    var identifier: String { get }

    /// Interrogate the engine. May spawn a process, so it is async and throwing.
    func capabilities() async throws -> EngineCapabilities

    /// Enumerate an archive's members and properties.
    ///
    /// Listing is request/response rather than streaming: it either produces a
    /// complete listing or throws. Progress during a listing is not useful — even a
    /// very large archive lists in well under a second because only headers are read.
    func list(_ request: ListRequest) async throws -> ArchiveListing

    /// Unpack members to disk.
    func extract(_ request: ExtractRequest) -> ArchiveOperationStream

    /// Verify members without writing anything.
    func test(_ request: TestRequest) -> ArchiveOperationStream

    /// Create a new archive, or add to / update an existing one.
    func compress(_ request: CompressRequest) -> ArchiveOperationStream

    /// Remove members from an archive.
    func delete(_ request: DeleteRequest) -> ArchiveOperationStream

    /// Rename members in place.
    func rename(_ request: RenameRequest) -> ArchiveOperationStream

    /// Compute digests of files or members.
    func hash(_ request: HashRequest) -> ArchiveOperationStream

    /// Run 7-Zip's compression benchmark.
    func benchmark(_ request: BenchmarkRequest) -> ArchiveOperationStream

    /// Stream one member's decompressed bytes without writing to disk.
    func readEntry(_ request: ReadEntryRequest) -> AsyncThrowingStream<Data, any Error>
}

// MARK: - Convenience

extension ArchiveOperationResult {
    /// Drain an operation stream, forwarding each event to `onEvent` and returning
    /// the terminal result.
    ///
    /// - Throws: whatever the stream throws, including ``ArchiveError/cancelled``.
    ///   Also throws ``ArchiveError/malformedOutput(_:)`` if the stream ends without
    ///   a ``ArchiveEvent/finished(_:)`` event, which would mean an engine broke its
    ///   own contract.
    public static func collecting(
        _ stream: ArchiveOperationStream,
        operation: ArchiveOperation,
        onEvent: (@Sendable (ArchiveEvent) -> Void)? = nil
    ) async throws -> ArchiveOperationResult {
        var result: ArchiveOperationResult?
        for try await event in stream {
            onEvent?(event)
            if case .finished(let finished) = event { result = finished }
        }
        guard let result else {
            throw ArchiveError.malformedOutput(
                "The \(operation.rawValue) operation ended without reporting a result."
            )
        }
        return result
    }
}

extension ArchiveEngine {
    /// Run an extraction to completion, ignoring intermediate events.
    @discardableResult
    public func extractAndWait(_ request: ExtractRequest) async throws -> ArchiveOperationResult {
        try await ArchiveOperationResult.collecting(extract(request), operation: .extract)
    }

    /// Run a test to completion.
    @discardableResult
    public func testAndWait(_ request: TestRequest) async throws -> ArchiveOperationResult {
        try await ArchiveOperationResult.collecting(test(request), operation: .test)
    }

    /// Run a compression to completion.
    @discardableResult
    public func compressAndWait(_ request: CompressRequest) async throws -> ArchiveOperationResult {
        try await ArchiveOperationResult.collecting(compress(request), operation: .compress)
    }

    /// Run a hash operation and return just the digests.
    public func hashAndWait(_ request: HashRequest) async throws -> [HashResult] {
        let result = try await ArchiveOperationResult.collecting(hash(request), operation: .hash)
        return result.hashes ?? []
    }

    /// Read one member fully into memory.
    ///
    /// Convenience for small members — previews, comment files, manifests. Anything
    /// that could be large should consume ``readEntry(_:)`` incrementally instead.
    ///
    /// - Throws: ``ArchiveError/outputLimitExceeded(_:)`` when the member is larger than
    ///   ``ReadEntryRequest/maximumByteCount``. The CLI engine raises it from the stream
    ///   itself; the check here is the same guard for an engine that does not.
    public func readEntryData(_ request: ReadEntryRequest) async throws -> Data {
        var data = Data()
        for try await chunk in readEntry(request) {
            data.append(chunk)
            if let limit = request.maximumByteCount, UInt64(data.count) > limit {
                throw ArchiveError.outputLimitExceeded(limit)
            }
        }
        return data
    }
}
