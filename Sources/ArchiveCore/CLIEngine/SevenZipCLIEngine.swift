// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// The shipping `ArchiveEngine`: drives the bundled upstream `7zz` as a subprocess.
//
// ## Why a subprocess
//
// `7zz` is vendored verbatim and executed as a separate program. That is what keeps
// this GPL-3.0 application compatible with an upstream that is LGPL-2.1+ *plus* the
// unRAR restriction: the RAR decoder carries a use-restriction that GPLv3 §7 treats
// as a forbidden "further restriction", so it must never be linked into our
// copyleft boundary. Two programs communicating over argv and pipes are separate
// works; see docs/ENGINE-PROTOCOL.md and NOTICE.
//
// It also buys process isolation — a malformed archive that crashes a decoder takes
// down a child, not the file manager — and turns a security update into a file swap.
//
// ## Cancellation
//
// The child is placed in its **own process group** at spawn, so cancelling signals
// the group rather than just the immediate child. `7zz` unwinds cleanly on SIGINT,
// deleting the partial archive it was writing, and exits 255. Note the asymmetry: a
// cancelled *extraction* leaves already-written files behind, and cleaning the
// destination is the caller's job.
//
// ## Passwords
//
// There is a hard asymmetry in `7zz`, verified empirically (res_3 §4a.7):
//
// - **Read paths** (`x`, `e`, `t`, `l`) accept the passphrase on **stdin**, so it
//   never appears in the process table.
// - **The creation path** (`a`) does **not**. It silently produces an *unencrypted*
//   archive unless `-p` is on the command line, where it is briefly visible to any
//   local process running `ps`.
//
// We therefore pass `-p` only where we must, and every encrypting creation is
// followed by `verifyEncryption(of:)`, which re-lists the archive and throws
// `.encryptionVerificationFailed` if the result is not actually encrypted. Silently
// handing the user a plaintext archive they believe is encrypted is the worst
// failure mode this component has.

import Foundation

/// Drives the bundled `7zz` binary.
public struct SevenZipCLIEngine: ArchiveEngine {
    // MARK: Configuration

    /// Absolute path to the `7zz` executable.
    public let executableURL: URL

    /// Timestamp zone requested from the child, and used when parsing its output.
    ///
    /// Kept in one place so the `-slt` parser and the child's environment can never
    /// disagree about what a bare `2026-08-24 17:00:00` means.
    public let timeZone: TimeZone

    /// Bytes read from a pipe per turn.
    let readChunkSize: Int

    public init(
        executableURL: URL,
        timeZone: TimeZone = .current,
        readChunkSize: Int = 64 * 1024
    ) {
        self.executableURL = executableURL
        self.timeZone = timeZone
        self.readChunkSize = max(readChunkSize, 4096)
    }

    public var identifier: String { "7zz-cli" }

    // MARK: Capabilities

    public func capabilities() async throws -> EngineCapabilities {
        let version = try await probeVersion()
        return EngineCapabilities(
            creatableFormats: Set(FormatCatalog.creatableFormats),
            readableFormats: Set(FormatCatalog.creatableFormats)
                .union(FormatCatalog.extractOnlyFormats.map(\.format)),
            providesExactByteProgress: false,
            keepsPasswordsInProcess: false,
            supportsBenchmark: true,
            supportsHashing: true,
            supportsStreamingSingleEntry: true,
            versionDescription: version
        )
    }

    /// Run `7zz` with no arguments and keep its banner line.
    private func probeVersion() async throws -> String {
        let run = try await ProcessRunner.runToCompletion(
            executableURL: executableURL,
            arguments: ["-y"],
            environment: environment()
        )
        let banner = run.standardOutput
            .split(separator: "\n")
            .map(String.init)
            .first(where: { $0.lowercased().contains("7-zip") })
        return banner?.trimmingCharacters(in: .whitespaces) ?? "7-Zip (unknown version)"
    }

    // MARK: Listing

    public func list(_ request: ListRequest) async throws -> ArchiveListing {
        let delivery = Self.readDelivery(request.password)
        var arguments = ["l"]
        arguments += Self.listSwitches(passwordOnStdin: delivery.usesStdin)
        if let format = request.formatOverride {
            arguments.append("-t\(format.rawValue)")
        }
        arguments.append("--")
        arguments.append(request.archiveURL.path)

        let run = try await ProcessRunner.runToCompletion(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment(),
            standardInput: delivery.stdinBytes
        )

        // Classify against BOTH streams. `-bso1` sends the log — including the
        // "Enter password:" prompt — to stdout, so inspecting stderr alone makes an
        // encrypted archive look like a generic failure instead of a password request.
        let diagnosticLines =
            run.standardError.split(separator: "\n").map(String.init)
            + run.standardOutput.split(separator: "\n").map(String.init)

        switch ExitCodeMapper.classify(
            exitCode: run.exitCode,
            terminationSignal: run.terminationSignal,
            stderrLines: diagnosticLines,
            path: request.archiveURL.path
        ) {
        case .success:
            let parser = SLTParser(archiveURL: request.archiveURL, timeZone: request.timeZone)
            return parser.parse(run.standardOutput)
        case .failure(let error):
            throw error
        }
    }

    // MARK: Streaming operations

    public func extract(_ request: ExtractRequest) -> ArchiveOperationStream {
        let delivery = Self.readDelivery(request.password)
        let command = request.pathMode == .noPaths ? "e" : "x"
        var arguments = [command]
        arguments += Self.commonSwitches(passwordOnStdin: delivery.usesStdin)
        arguments.append("-o\(request.destinationURL.path)")
        arguments.append(contentsOf: Self.overwriteSwitch(request.overwriteMode))
        if let format = request.formatOverride { arguments.append("-t\(format.rawValue)") }
        if request.pathMode == .absolutePaths { arguments.append("-spf2") }
        if request.keepBrokenFiles { arguments.append("-tzip:kb") }
        // A large selection cannot go on argv: ARG_MAX is 1 MiB and posix_spawn fails
        // with an opaque E2BIG well before the user thinks they have selected "a lot".
        // The list-file switch has to precede `--`, hence the ordering here.
        let selection: SelectionListFile.Prepared
        do {
            selection = try SelectionListFile.prepare(request.selectedEntries)
        } catch {
            return Self.failedStream(.extract, error)
        }
        arguments.append(contentsOf: selection.switches)
        arguments.append("--")
        arguments.append(request.archiveURL.path)
        arguments.append(contentsOf: selection.arguments)

        return runStreaming(
            operation: .extract,
            arguments: arguments,
            delivery: delivery,
            path: request.archiveURL.path,
            temporaryFiles: selection.temporaryFiles
        )
    }

    public func test(_ request: TestRequest) -> ArchiveOperationStream {
        let delivery = Self.readDelivery(request.password)
        var arguments = ["t"]
        arguments += Self.commonSwitches(passwordOnStdin: delivery.usesStdin)
        if let format = request.formatOverride { arguments.append("-t\(format.rawValue)") }
        // A large selection cannot go on argv: ARG_MAX is 1 MiB and posix_spawn fails
        // with an opaque E2BIG well before the user thinks they have selected "a lot".
        // The list-file switch has to precede `--`, hence the ordering here.
        let selection: SelectionListFile.Prepared
        do {
            selection = try SelectionListFile.prepare(request.selectedEntries)
        } catch {
            return Self.failedStream(.test, error)
        }
        arguments.append(contentsOf: selection.switches)
        arguments.append("--")
        arguments.append(request.archiveURL.path)
        arguments.append(contentsOf: selection.arguments)

        return runStreaming(
            operation: .test,
            arguments: arguments,
            delivery: delivery,
            path: request.archiveURL.path,
            temporaryFiles: selection.temporaryFiles
        )
    }

    public func compress(_ request: CompressRequest) -> ArchiveOperationStream {
        // Creation has no stdin prompt: the passphrase must go on argv. See
        // PasswordDelivery.
        var arguments = [Self.updateCommand(request.updateMode)]
        arguments += Self.commonSwitches(passwordOnStdin: false)
        arguments += Self.updateSwitches(request.updateMode)
        arguments.append("-t\(request.format.rawValue)")
        arguments.append(contentsOf: CompressArgumentBuilder.methodSwitches(for: request))
        arguments.append(contentsOf: CompressArgumentBuilder.pathModeSwitches(for: request))

        // Creation cannot take the passphrase on stdin. See the file header.
        if let encryption = request.encryption, !encryption.password.isEmpty {
            arguments.append("-p\(encryption.password)")

            // `-mem=` is a ZIP-only switch. `.7z` supports AES-256 and nothing else,
            // and passing `-mem` to the 7z handler is rejected outright:
            //
            //     $ 7zz a -t7z -pX -mem=aes256 out.7z in.txt
            //     System ERROR: E_INVALIDARG : One or more arguments are invalid
            //
            // Verified against the vendored 26.02 binary; covered by
            // LiveEngineTests.encryptedRoundTrip.
            if request.format == .zip {
                arguments.append("-mem=\(encryption.method.switchValue)")
            }

            // Header encryption hides the file *names*, not just their contents.
            // `.7z` only.
            if encryption.encryptFileNames, request.format == .sevenZip {
                arguments.append("-mhe=on")
            }
        }
        arguments.append("--")
        arguments.append(request.archiveURL.path)
        arguments.append(contentsOf: Self.inputArguments(for: request))

        let wantsEncryption = !(request.encryption?.password ?? "").isEmpty
        let archiveURL = Self.verificationTarget(for: request)
        let encryptionPassword = request.encryption?.password
        let engine = self

        // Bound explicitly rather than as a ternary: the type checker cannot infer an
        // optional `@Sendable` async closure through `?:` and times out trying.
        var verify: (@Sendable () async throws -> Void)?
        if wantsEncryption {
            verify = { try await engine.verifyEncryption(of: archiveURL, password: encryptionPassword) }
        }

        return runStreaming(
            operation: .compress,
            arguments: arguments,
            delivery: .absent,
            path: request.archiveURL.path,
            // Run from baseDirectory when the caller set one. `inputArguments(for:)`
            // hands 7zz paths RELATIVE to it, so without this the child resolves them
            // against OUR working directory and reports
            // "docs/img : errno=2 : No such file or directory" — a scan warning, not an
            // error, so the operation "succeeds" having added nothing at all.
            currentDirectory: request.baseDirectory,
            afterSuccess: verify
        )
    }

    public func delete(_ request: DeleteRequest) -> ArchiveOperationStream {
        let delivery = Self.readDelivery(request.password)
        var arguments = ["d"]
        arguments += Self.commonSwitches(passwordOnStdin: delivery.usesStdin)
        arguments.append("--")
        arguments.append(request.archiveURL.path)
        arguments.append(contentsOf: request.entryPaths)
        return runStreaming(
            operation: .delete,
            arguments: arguments,
            delivery: delivery,
            path: request.archiveURL.path
        )
    }

    public func rename(_ request: RenameRequest) -> ArchiveOperationStream {
        let delivery = Self.readDelivery(request.password)
        var arguments = ["rn"]
        arguments += Self.commonSwitches(passwordOnStdin: delivery.usesStdin)
        arguments.append("--")
        arguments.append(request.archiveURL.path)
        for pair in request.renames {
            arguments.append(pair.oldPath)
            arguments.append(pair.newPath)
        }
        return runStreaming(
            operation: .rename,
            arguments: arguments,
            delivery: delivery,
            path: request.archiveURL.path
        )
    }

    public func hash(_ request: HashRequest) -> ArchiveOperationStream {
        let delivery = Self.readDelivery(request.password)
        var arguments = ["h"]
        arguments += Self.commonSwitches(passwordOnStdin: delivery.usesStdin)
        arguments.append("-scrc\(request.algorithm.switchValue)")
        arguments.append("--")
        switch request.source {
        case .files(let urls):
            arguments.append(contentsOf: urls.map(\.path))
        case let .archiveEntries(archiveURL, entryPaths):
            // Hashing members means decompressing them, so this is an extract-to-stdout
            // with hashing rather than a plain `h` over files.
            arguments.append(archiveURL.path)
            if let entryPaths { arguments.append(contentsOf: entryPaths) }
        }
        return runStreaming(
            operation: .hash,
            arguments: arguments,
            delivery: delivery,
            path: nil
        )
    }

    public func benchmark(_ request: BenchmarkRequest) -> ArchiveOperationStream {
        var arguments = ["b"]
        arguments += Self.commonSwitches(passwordOnStdin: false)
        if request.passes > 0 { arguments.append("-mmt\(request.passes)") }
        if let dictionary = request.dictionarySize { arguments.append("-md\(dictionary)") }
        if let threads = request.threads { arguments.append("-mmt\(threads)") }
        return runStreaming(operation: .benchmark, arguments: arguments, delivery: .absent, path: nil)
    }

    // MARK: Single-entry streaming

    public func readEntry(_ request: ReadEntryRequest) -> AsyncThrowingStream<Data, any Error> {
        // `-so` writes the member to stdout. Progress must be silenced entirely, or it
        // would be interleaved into the payload.
        let delivery = Self.readDelivery(request.password)
        var arguments = ["x", "-so", "-bsp0", "-bso0", "-bse2", "-scsUTF-8"]
        if !delivery.usesStdin { arguments.insert("-y", at: 2) }
        if let format = request.formatOverride { arguments.append("-t\(format.rawValue)") }
        arguments.append("--")
        arguments.append(request.archiveURL.path)
        arguments.append(request.entryPath)

        let executable = executableURL
        let env = environment()
        let stdin = delivery.stdinBytes
        let limit = request.maximumByteCount
        let chunk = readChunkSize
        let archivePath = request.archiveURL.path
        // Bound to a `let`: a captured `var` is shared mutable state as far as the
        // Swift 6 checker is concerned, and the escaping task closure is `sending`.
        let finalArguments = arguments

        return AsyncThrowingStream { continuation in
            let task = Task {
                var stderrText = Data()
                do {
                    for try await event in ProcessRunner.stream(
                        executableURL: executable,
                        arguments: finalArguments,
                        environment: env,
                        standardInput: stdin,
                        readChunkSize: chunk,
                        byteLimit: limit
                    ) {
                        switch event {
                        case .standardOutput(let data):
                            continuation.yield(data)
                        case .standardError(let data):
                            stderrText.append(data)
                        case .finished(let completion):
                            let lines = EngineText.decode(stderrText)
                                .split(separator: "\n").map(String.init)
                            switch ExitCodeMapper.classify(
                                exitCode: completion.exitCode,
                                terminationSignal: completion.terminationSignal,
                                stderrLines: lines,
                                path: archivePath,
                                wasCancelled: Task.isCancelled
                            ) {
                            case .success:
                                continuation.finish()
                            case .failure(let error):
                                continuation.finish(throwing: error)
                            }
                        }
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Command construction

extension SevenZipCLIEngine {
    // MARK: Switches

    /// Switches applied to every invocation.
    ///
    /// Each one earns its place; see docs/ENGINE-PROTOCOL.md §3.
    ///
    /// - `-y` assume Yes. **Mandatory.** Any prompt with stdin closed makes `7zz`
    ///   print "Break signaled" and exit 255, which is indistinguishable from a real
    ///   cancellation without output sniffing.
    /// - `-bb3` per-member log lines, which is what drives item events.
    /// - `-bso1` log to stdout, `-bsp2` progress to stderr, `-bse2` errors to stderr.
    ///   Splitting the streams is what lets the tokenizer treat stdout as pure
    ///   newline-terminated text and stderr as backspace-painted progress.
    /// - `-scsUTF-8` / `-sccUTF-8` UTF-8 for list files and console output.
    static let commonSwitches = commonSwitches(passwordOnStdin: false)

    /// Switches for every invocation.
    ///
    /// - Parameter passwordOnStdin: when `true`, `-y` is omitted so `7zz` will emit
    ///   its "Enter password:" prompt and read the answer from our pipe. See
    ///   ``passwordDelivery(for:)`` for why that matters.
    static func commonSwitches(passwordOnStdin: Bool) -> [String] {
        var switches = [
            "-bb3",
            "-bso1",
            "-bsp2",
            "-bse2",
            "-scsUTF-8",
            "-sccUTF-8",
        ]
        if !passwordOnStdin { switches.insert("-y", at: 0) }
        return switches
    }

    /// Switches for a listing, which wants no progress painting at all.
    static func listSwitches(passwordOnStdin: Bool) -> [String] {
        var switches = ["-slt", "-bso1", "-bsp0", "-bse2", "-scsUTF-8", "-sccUTF-8"]
        if !passwordOnStdin { switches.insert("-y", at: 0) }
        return switches
    }

    // MARK: Password delivery

    /// How a passphrase reaches `7zz` for a given operation.
    ///
    /// Verified empirically against the vendored 26.02 binary, and it is **not** what
    /// the switch documentation implies:
    ///
    /// - A **bare `-p`** does not mean "read the password from stdin". It means an
    ///   *empty* password, and it overrides the prompt. Using it on an encrypted
    ///   archive fails with "Cannot open encrypted archive. Wrong password?".
    /// - Omitting **both** `-y` and `-p` makes `7zz` print `Enter password:` and read
    ///   the answer from stdin — a pipe works, no TTY required. This is the secure
    ///   path: the passphrase never appears in the process table.
    /// - The **creation** path has no such prompt. `7zz a` with no `-p` does not ask;
    ///   it writes an **unencrypted** archive and exits **0**. The passphrase must go
    ///   on argv as `-p<pw>`, where `ps` can see it, and the result must then be
    ///   verified — see ``verifyEncryption(of:password:)``.
    enum PasswordDelivery {
        /// No passphrase involved; `-y` is safe.
        case absent
        /// Prompt-driven, read from our pipe. `-y` must be omitted.
        case stdin(String)
        /// On argv. Visible in `ps`. Creation only.
        case argv(String)

        var usesStdin: Bool { if case .stdin = self { return true }; return false }

        var stdinBytes: Data? {
            guard case .stdin(let password) = self else { return nil }
            return Data((password + "\n").utf8)
        }
    }

    /// Delivery for a read operation (list, test, extract, readEntry).
    static func readDelivery(_ password: String?) -> PasswordDelivery {
        guard let password, !password.isEmpty else { return .absent }
        return .stdin(password)
    }
}

// MARK: - Running the child

extension SevenZipCLIEngine {
    // MARK: The streaming core

    /// Spawn `7zz`, translate its output into events, and finish or throw.
    func runStreaming(
        operation: ArchiveOperation,
        arguments: [String],
        delivery: PasswordDelivery,
        path: String?,
        currentDirectory: URL? = nil,
        temporaryFiles: [URL] = [],
        afterSuccess: (@Sendable () async throws -> Void)? = nil
    ) -> ArchiveOperationStream {
        let executable = executableURL
        let env = environment()
        let stdin = delivery.stdinBytes
        let chunk = readChunkSize

        return AsyncThrowingStream { continuation in
            let task = Task {
                var run = RunAccumulator(operation: operation)
                continuation.yield(.started(operation))

                do {
                    for try await event in ProcessRunner.stream(
                        executableURL: executable,
                        arguments: arguments,
                        environment: env,
                        standardInput: stdin,
                        readChunkSize: chunk,
                        currentDirectory: currentDirectory
                    ) {
                        switch event {
                        case .standardOutput(let data):
                            Self.emit(run.consumeStandardOutput(data), to: continuation)

                        case .standardError(let data):
                            Self.emit(run.consumeStandardError(data), to: continuation)

                        case .finished(let completion):
                            Self.emit(run.finish(), to: continuation)
                            switch run.outcome(for: completion, path: path) {
                            case .success:
                                if let afterSuccess { try await afterSuccess() }
                                continuation.yield(.finished(run.result))
                                continuation.finish()
                            case .failure(let error):
                                continuation.finish(throwing: error)
                            }
                        }
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                for url in temporaryFiles { try? FileManager.default.removeItem(at: url) }
            }
        }
    }

    /// Hand a batch of events to the consumer, in the order they were produced.
    private static func emit(_ events: [ArchiveEvent], to continuation: ArchiveOperationStream.Continuation) {
        for event in events { continuation.yield(event) }
    }

    // MARK: Run state

    /// The state one streaming run builds up as it consumes the child's output.
    ///
    /// Lifted out of ``runStreaming(operation:arguments:delivery:path:afterSuccess:)``
    /// so the run loop reads as "fold in a chunk, yield what it produced" instead of
    /// as one long closure carrying seven mutable locals. Confined to the consuming
    /// task, so there is nothing to share and nothing to lock.
    private struct RunAccumulator {
        let operation: ArchiveOperation
        var parser: ProgressParser
        var outTokenizer = StreamTokenizer()
        var errTokenizer = StreamTokenizer()
        var warnings: [ArchiveWarning] = []
        var stderrLines: [String] = []
        var logLines: [String] = []
        var itemCount = 0

        init(operation: ArchiveOperation) {
            self.operation = operation
            self.parser = ProgressParser(operation: operation)
        }

        /// Fold in a chunk of stdout, returning the events it produced.
        mutating func consumeStandardOutput(_ data: Data) -> [ArchiveEvent] {
            absorb(parser.consume(outTokenizer.consume(data)))
        }

        /// Fold in a chunk of stderr, keeping its complete lines for classification.
        mutating func consumeStandardError(_ data: Data) -> [ArchiveEvent] {
            absorb(parser.consume(recordingLines(errTokenizer.consume(data))))
        }

        /// Flush both tokenizers once the child has exited.
        mutating func finish() -> [ArchiveEvent] {
            var events = absorb(parser.consume(outTokenizer.finish()))
            events += absorb(parser.consume(recordingLines(errTokenizer.finish())))
            return events
        }

        /// What the caller should do with the finished child.
        func outcome(for completion: ProcessRunner.Completion, path: String?) -> ExitCodeMapper.Outcome {
            ExitCodeMapper.classify(
                exitCode: completion.exitCode,
                terminationSignal: completion.terminationSignal,
                // Both streams: the password prompt is written to the
                // stdout log, not to stderr. See list().
                stderrLines: stderrLines + logLines,
                warnings: warnings,
                path: path,
                wasCancelled: Task.isCancelled
            )
        }

        /// What a successful run reports.
        var result: ArchiveOperationResult {
            ArchiveOperationResult(
                operation: operation,
                warnings: warnings,
                itemsProcessed: itemCount,
                log: logLines
            )
        }

        /// Record what the parser produced and return the events to yield for it.
        private mutating func absorb(_ outputs: [ProgressParser.Output]) -> [ArchiveEvent] {
            var events: [ArchiveEvent] = []
            for output in outputs {
                switch output {
                case .progress(let progress):
                    events.append(.progress(progress))
                case .item(let item):
                    itemCount += 1
                    events.append(.item(item))
                case .log(let line):
                    logLines.append(line)
                    events.append(.log(line))
                case .warning(let warning):
                    warnings.append(warning)
                    events.append(.warning(warning))
                case .ignored:
                    break
                }
            }
            return events
        }

        /// Keep every complete line for the exit classifier, passing the tokens on.
        private mutating func recordingLines(
            _ tokens: [StreamTokenizer.Token]
        ) -> [StreamTokenizer.Token] {
            for token in tokens where token.isLine { stderrLines.append(token.text) }
            return tokens
        }
    }

    /// The input paths to hand `7zz`, relative to `baseDirectory` when there is one.
    ///
    /// `7zz a` stores every input under the path it was GIVEN. Passing absolute paths
    /// stores absolute paths, which is why adding into a subfolder needs both a working
    /// directory AND relative inputs — the working directory alone changes nothing if the
    /// arguments are still absolute.
    ///
    /// An input outside `baseDirectory` cannot be expressed relatively, so it keeps its
    /// absolute path rather than being silently mangled into a `../..` chain that would
    /// store a nonsense member name.
    static func inputArguments(for request: CompressRequest) -> [String] {
        guard let base = request.baseDirectory?.standardizedFileURL else {
            return request.inputs.map(\.path)
        }
        let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
        return request.inputs.map { input in
            let path = input.standardizedFileURL.path
            guard path.hasPrefix(basePath) else { return path }
            return String(path.dropFirst(basePath.count))
        }
    }

    /// A stream that fails immediately, for errors raised before the child is spawned.
    static func failedStream(
        _ operation: ArchiveOperation, _ error: any Error
    ) -> ArchiveOperationStream {
        AsyncThrowingStream { continuation in
            continuation.yield(.started(operation))
            continuation.finish(throwing: error)
        }
    }

    // MARK: Encryption verification

    /// The path to re-list when checking that encryption took.
    ///
    /// With `-v`, 7zz writes `archive.7z.001`, `archive.7z.002`, ... and never creates
    /// `archive.7z` itself. Listing the base name then exits 2 with
    /// `errno=2 : No such file or directory`, so verification threw and every encrypted
    /// multi-volume compression was reported to the user as a failure — despite having
    /// succeeded, and despite the volumes being correctly encrypted.
    ///
    /// The first volume is always `.001`: 7-Zip pads to three digits and only widens past
    /// 999, so the first piece keeps that name for any split count.
    static func verificationTarget(for request: CompressRequest) -> URL {
        guard !request.volumeSizes.isEmpty else { return request.archiveURL }
        return URL(fileURLWithPath: request.archiveURL.path + ".001")
    }

    /// Re-list a freshly created archive and confirm it really is encrypted.
    ///
    /// Guards the failure mode where `-p` was dropped or ignored and the user is
    /// handed a plaintext archive they believe is protected.
    func verifyEncryption(of url: URL, password: String?) async throws {
        let listing = try await list(
            ListRequest(archiveURL: url, password: password, timeZone: timeZone)
        )
        guard listing.isEncrypted else {
            throw ArchiveError.encryptionVerificationFailed(
                "\(url.lastPathComponent) was created without encryption despite a password being supplied."
            )
        }
    }

    // MARK: Helpers

    /// Child environment.
    ///
    /// `LC_ALL=C.UTF-8` pins the message language so output sniffing in
    /// `ExitCodeMapper` is not defeated by a localised build, and `TZ` pins the zone
    /// that bare `-slt` timestamps are printed in.
    func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "C.UTF-8"
        env["LANG"] = "C.UTF-8"
        env["TZ"] = timeZone.identifier
        return env
    }

    /// The `7zz` command letter for an update mode.
    ///
    /// All four modes use `a`; they differ in the `-u` switch block, because 7-Zip
    /// expresses "freshen" and "synchronize" as update-action specifiers rather than
    /// as separate commands. See docs/ENGINE-PROTOCOL.md §2.
    static func updateCommand(_ mode: UpdateMode) -> String { "a" }

    /// The `-u` switch block for an update mode, empty for the default.
    static func updateSwitches(_ mode: UpdateMode) -> [String] {
        switch mode {
        case .addAndReplace:   []                  // 7-Zip's default behaviour.
        case .updateAndAdd:    ["-uq0"]
        case .freshenExisting: ["-ur0"]
        case .synchronize:     ["-up0q0r2x2y2z1w2"]
        }
    }

    /// The `-ao*` switch for an overwrite mode.
    ///
    /// `.ask` maps to `-aos` (SKIP), and that choice is load-bearing.
    ///
    /// It previously emitted NOTHING, on the reasoning that `-y` "already forces a
    /// decision". It does — it answers YES. So an extraction the user had explicitly set
    /// to "Ask before overwrite" destroyed their files with no prompt, reported
    /// "Everything is Ok", and exited 0. That shipped in 0.1.0.
    ///
    /// The engine cannot ask anyone anything: `7zz` has no interactive channel once it is
    /// running, which is why the UI resolves conflicts up front and is supposed to hand
    /// down a concrete mode. `.ask` arriving here therefore means the UI failed to
    /// resolve it — a bug — and the only safe reading of "the user wanted to be asked and
    /// nobody asked them" is DO NOT TOUCH THEIR FILES. Skipping loses nothing: the
    /// archive still holds every member, and the user can extract again.
    static func overwriteSwitch(_ mode: OverwriteMode) -> [String] {
        switch mode {
        case .ask: ["-aos"]
        case .overwrite: ["-aoa"]
        case .skip: ["-aos"]
        case .autoRename: ["-aou"]
        case .autoRenameExisting: ["-aot"]
        }
    }
}
