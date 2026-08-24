// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte

import Foundation

/// A byte-level tokenizer for the output of `7zz`.
///
/// # Why this file exists
///
/// `7zz` does not write a machine protocol. It writes to a terminal, and it erases
/// its in-place progress indicator with **backspace characters (`0x08`), not
/// carriage returns**. This is the single most commonly mis-handled fact about
/// driving 7-Zip as a subprocess: a reader built on `readLine()`, on splitting at
/// `\n`, or on the usual `\r`-based progress assumption sees one enormous line and
/// reports nothing at all until the process exits.
///
/// Verified raw output of `7zz x -bsp1 -bb3`, shown through `cat -v` (res_3 §4a.5):
///
/// ```text
///   0%^H^H^H^H    ^H^H^H^H- src
///   0% 1^H^H^H^H^H^H      ^H^H^H^H^H^H- src/big.bin
///  34% 2^H^H^H^H^H^H      ^H^H^H^H^H^H- src/café_日本.txt
/// 100% 5^H^H^H^H^H^H      ^H^H^H^H^HEverything is Ok
/// ```
///
/// The pattern is always: **write a token → N backspaces → N spaces → N backspaces**.
/// Note the last line: only *five* backspaces follow the six spaces, so one space
/// survives and `Everything is Ok` is written one column in. Any tokenizer that
/// models backspace as "delete the last byte" gets that line wrong; a tokenizer that
/// models a cursor gets it right.
///
/// # The model
///
/// This type is a **one-row terminal emulator**. It maintains the bytes currently
/// displayed on the row plus a **cursor measured in Unicode scalars, not bytes**,
/// because 7-Zip emits one backspace per character it printed, and a path like
/// `café_日本.txt` has far fewer characters than bytes. Byte-counting backspaces
/// against multi-byte UTF-8 corrupts every non-ASCII progress token.
///
/// | Input | Effect |
/// | --- | --- |
/// | printable byte | write one scalar at the cursor, advance |
/// | `\b` (0x08) | move the cursor back one **scalar**, clamped at column 0 |
/// | `\r` (0x0D) | move the cursor to column 0 |
/// | `\r\n` | end of line |
/// | `\n` (0x0A) | end of line |
///
/// # What it emits
///
/// - ``Token/line(_:)`` — the row's full contents when a newline ends it. These are
///   the permanent records: `-bb` per-file log lines, `-slt` `Key = Value` lines,
///   `ERROR:` lines, the blank lines that separate `-slt` items. **Empty lines are
///   emitted**, because the `-slt` grammar uses them as item separators.
/// - ``Token/transient(_:)`` — the row's contents captured *at the instant it is
///   about to be erased*, i.e. on the first backspace of a run or on a `\r`. These
///   are the progress ticks. Whitespace-only transients are suppressed, which
///   removes the space-blanking half of the erase pattern.
///
/// So the four-line sample above tokenizes to:
/// `transient("  0%")`, `line("- src")`, `transient("  0% 1")`, `line("- src/big.bin")`, …,
/// `transient("100% 5")`, `line(" Everything is Ok")` — note the leading space,
/// which is genuinely on the terminal row and which
/// ``ProgressParser`` therefore tolerates.
///
/// # Guarantees
///
/// - **Chunk boundaries are invisible.** State persists across ``consume(_:)``
///   calls, so a token, a backspace run, or a multi-byte UTF-8 sequence may be split
///   anywhere. This is not a theoretical concern: a pipe read returns whatever
///   happens to be buffered.
/// - **UTF-8 is decoded incrementally.** A sequence straddling a chunk boundary is
///   held until it completes. Malformed bytes become `U+FFFD` rather than being
///   dropped or aborting the stream, so a filename in a broken encoding still
///   produces a usable token.
/// - **No TTY required.** Every capture the design is based on was redirected to a
///   file, and `7zz` emits progress identically either way — which is precisely why
///   driving it as a subprocess is viable at all without a pty (res_3 §4a.5).
/// - **Bounded memory.** A row longer than ``Options/maximumRowBytes`` is force-
///   flushed as a line and ``didTruncateOversizedRow`` is set, so a hostile archive
///   containing a megabyte-long filename cannot grow the buffer without limit.
///
/// # One deliberate deviation from terminal behaviour
///
/// When a write lands *before* the end of the retained row, this tokenizer discards
/// the remainder of the row rather than keeping it as residue. A real terminal keeps
/// it. The deviation is safe for `7zz`, which always blanks a region with spaces
/// before rewriting it, and it is an improvement for any other producer: a `\r`-
/// rewritten line that got shorter does not leave stale tail characters behind.
///
/// # Thread safety
///
/// A value type with no reference storage. Confine one instance to one stream —
/// stdout and stderr each need their own, since they are independent rows.
public struct StreamTokenizer: Sendable {

    // MARK: Token

    /// One unit of output.
    public enum Token: Sendable, Hashable {
        /// A row terminated by a newline. Permanent output.
        ///
        /// Emitted verbatim, including leading and trailing spaces: a filename may
        /// legitimately begin or end with a space, and trimming here would corrupt
        /// it. Empty strings are emitted and are meaningful.
        case line(String)

        /// A row captured at the moment it was about to be erased. Progress output.
        case transient(String)

        /// The row text, whichever kind this is.
        public var text: String {
            switch self {
            case .line(let text), .transient(let text): text
            }
        }

        /// `true` for ``line(_:)``.
        public var isLine: Bool {
            if case .line = self { return true }
            return false
        }
    }

    // MARK: Options

    /// Tuning knobs. The defaults are what the CLI engine uses.
    public struct Options: Sendable, Hashable {
        /// Force-flush a row that reaches this many bytes.
        ///
        /// 1 MiB is far beyond any legitimate `7zz` row (`PATH_MAX` is 1024) while
        /// still being cheap, so hitting it is a reliable signal that the stream is
        /// not what we think it is.
        public var maximumRowBytes: Int

        /// Drop transient tokens that contain nothing but spaces and tabs.
        ///
        /// On by default: the space-blanking step of the erase pattern would
        /// otherwise emit one useless transient per progress tick.
        public var suppressBlankTransients: Bool

        public init(maximumRowBytes: Int = 1 << 20, suppressBlankTransients: Bool = true) {
            self.maximumRowBytes = max(maximumRowBytes, 16)
            self.suppressBlankTransients = suppressBlankTransients
        }

        public static let `default` = Options()
    }

    // MARK: Stored state

    private let options: Options

    /// Bytes currently displayed on the row.
    private var rowBytes: [UInt8] = []

    /// Byte offset at which each scalar cell starts. `cellOffsets.count` is the
    /// row's width in scalars.
    private var cellOffsets: [Int] = []

    /// Cursor position, in cells. Ranges over `0...cellOffsets.count`.
    private var cursor: Int = 0

    /// Bytes of a UTF-8 sequence that has not finished arriving.
    private var partialScalar: [UInt8] = []

    /// `true` while consuming a run of backspaces, so the transient is captured once
    /// per run rather than once per backspace.
    private var isErasing = false

    /// `true` when a `\r` has been seen and we are waiting to find out whether the
    /// next byte is `\n` (making it a CRLF line ending) or something else (making it
    /// a cursor-home).
    private var pendingCarriageReturn = false

    /// Set when a row exceeded ``Options/maximumRowBytes`` and was force-flushed.
    public private(set) var didTruncateOversizedRow = false

    public init(options: Options = .default) {
        self.options = options
    }

    // MARK: Byte constants

    private static let lineFeed: UInt8 = 0x0A
    private static let carriageReturn: UInt8 = 0x0D
    private static let backspace: UInt8 = 0x08
    private static let space: UInt8 = 0x20
    private static let tab: UInt8 = 0x09
    private static let replacementCharacterBytes: [UInt8] = [0xEF, 0xBF, 0xBD] // U+FFFD

    // MARK: Public API

    /// Feed a chunk of bytes and collect whatever tokens they complete.
    ///
    /// Safe to call with any chunking, including one byte at a time and including
    /// chunks that split a token, a backspace run, or a UTF-8 sequence.
    public mutating func consume(_ bytes: some Sequence<UInt8>) -> [Token] {
        var tokens: [Token] = []
        for byte in bytes {
            consume(byte: byte, into: &tokens)
        }
        return tokens
    }

    /// Feed a `Data` chunk.
    public mutating func consume(_ data: Data) -> [Token] {
        data.withUnsafeBytes { raw -> [Token] in
            var tokens: [Token] = []
            for byte in raw.bindMemory(to: UInt8.self) {
                consume(byte: byte, into: &tokens)
            }
            return tokens
        }
    }

    /// Flush what is left when the stream reaches EOF.
    ///
    /// Emits the residual row as a ``Token/line(_:)`` — an unterminated final line is
    /// still a line — unless it is entirely whitespace, which is what a stream that
    /// ended mid-erase leaves behind and which carries no information.
    ///
    /// Call exactly once, after the producer has closed. The tokenizer is reusable
    /// afterwards; ``didTruncateOversizedRow`` is not reset.
    public mutating func finish() -> [Token] {
        var tokens: [Token] = []
        flushPartialScalar()
        if !rowBytes.isEmpty, containsNonWhitespace(rowBytes) {
            tokens.append(.line(currentRowText()))
        }
        resetRow()
        pendingCarriageReturn = false
        isErasing = false
        return tokens
    }

    /// Bytes currently held for an incomplete row. Diagnostics only.
    public var pendingByteCount: Int { rowBytes.count + partialScalar.count }

    /// Tokenize a complete byte sequence in one call. Convenience for tests and for
    /// output that was captured whole.
    public static func tokenize(_ bytes: [UInt8], options: Options = .default) -> [Token] {
        var tokenizer = StreamTokenizer(options: options)
        var tokens = tokenizer.consume(bytes)
        tokens.append(contentsOf: tokenizer.finish())
        return tokens
    }

    /// Tokenize a complete string in one call.
    public static func tokenize(_ text: String, options: Options = .default) -> [Token] {
        tokenize(Array(text.utf8), options: options)
    }

    // MARK: Core

    private mutating func consume(byte: UInt8, into tokens: inout [Token]) {
        // Resolve a pending `\r` first: only now do we know whether it was a CRLF
        // line ending or a bare cursor-home.
        if pendingCarriageReturn {
            pendingCarriageReturn = false
            if byte == Self.lineFeed {
                endRow(into: &tokens)
                return
            }
            // Bare `\r`: the row is about to be overwritten, so publish it.
            emitTransient(into: &tokens)
            cursor = 0
            isErasing = false
            // Fall through and process `byte` at the new cursor position.
        }

        // Control bytes cannot appear inside a multi-byte UTF-8 sequence (every
        // continuation byte has its high bit set), so it is always safe to test for
        // them before feeding the decoder.
        switch byte {
        case Self.lineFeed:
            flushPartialScalar()
            endRow(into: &tokens)

        case Self.carriageReturn:
            flushPartialScalar()
            pendingCarriageReturn = true

        case Self.backspace:
            flushPartialScalar()
            if !isErasing {
                // First backspace of a run: this is the moment the row is complete
                // and about to be destroyed, so it is the moment to publish it.
                emitTransient(into: &tokens)
                isErasing = true
            }
            if cursor > 0 { cursor -= 1 }

        default:
            isErasing = false
            appendByte(byte)
            if rowBytes.count > options.maximumRowBytes {
                didTruncateOversizedRow = true
                flushPartialScalar()
                tokens.append(.line(currentRowText()))
                resetRow()
            }
        }
    }

    /// Finish the current row and emit it as a line.
    private mutating func endRow(into tokens: inout [Token]) {
        flushPartialScalar()
        tokens.append(.line(currentRowText()))
        resetRow()
        isErasing = false
    }

    private mutating func emitTransient(into tokens: inout [Token]) {
        flushPartialScalar()
        guard !rowBytes.isEmpty else { return }
        if options.suppressBlankTransients, !containsNonWhitespace(rowBytes) { return }
        tokens.append(.transient(currentRowText()))
    }

    private mutating func resetRow() {
        rowBytes.removeAll(keepingCapacity: true)
        cellOffsets.removeAll(keepingCapacity: true)
        cursor = 0
        partialScalar.removeAll(keepingCapacity: true)
    }

    private func currentRowText() -> String {
        String(decoding: rowBytes, as: UTF8.self)
    }

    private func containsNonWhitespace(_ bytes: [UInt8]) -> Bool {
        bytes.contains { $0 != Self.space && $0 != Self.tab }
    }

    // MARK: Cell writing

    /// Write one complete scalar (given as its UTF-8 bytes) at the cursor.
    ///
    /// When the cursor is before the end of the row, the remainder of the row is
    /// dropped — see the "deliberate deviation" note in the type documentation.
    private mutating func writeCell(_ scalarBytes: [UInt8]) {
        if cursor < cellOffsets.count {
            let byteOffset = cellOffsets[cursor]
            rowBytes.removeSubrange(byteOffset...)
            cellOffsets.removeSubrange(cursor...)
        }
        cellOffsets.append(rowBytes.count)
        rowBytes.append(contentsOf: scalarBytes)
        cursor = cellOffsets.count
    }

    // MARK: Incremental UTF-8

    /// Feed one non-control byte to the incremental decoder, writing a cell as soon
    /// as a complete scalar has arrived.
    private mutating func appendByte(_ byte: UInt8) {
        if partialScalar.isEmpty {
            if byte < 0x80 {
                writeCell([byte])
                return
            }
            guard let expected = Self.utf8SequenceLength(leadByte: byte) else {
                // A stray continuation byte or an invalid lead byte: one replacement
                // character, and carry on. Never abandon the stream over encoding.
                writeCell(Self.replacementCharacterBytes)
                return
            }
            partialScalar = [byte]
            if expected == 1 { completePartialScalar() }
            return
        }

        // Mid-sequence. A byte that is not a continuation byte means the previous
        // sequence was truncated; publish a replacement character for it and
        // reprocess the new byte as a fresh lead.
        guard byte & 0xC0 == 0x80 else {
            writeCell(Self.replacementCharacterBytes)
            partialScalar.removeAll(keepingCapacity: true)
            appendByte(byte)
            return
        }

        partialScalar.append(byte)
        if let expected = Self.utf8SequenceLength(leadByte: partialScalar[0]),
           partialScalar.count >= expected {
            completePartialScalar()
        } else if partialScalar.count >= 4 {
            completePartialScalar()
        }
    }

    /// Decode the buffered sequence and write it as one cell.
    ///
    /// `String(decoding:as:)` substitutes `U+FFFD` for anything malformed, which is
    /// exactly the behaviour we want: an over-long encoding or a surrogate escapes as
    /// a visible replacement character instead of corrupting the row.
    private mutating func completePartialScalar() {
        guard !partialScalar.isEmpty else { return }
        let decoded = String(decoding: partialScalar, as: UTF8.self)
        partialScalar.removeAll(keepingCapacity: true)
        // A malformed sequence can decode to more than one replacement character;
        // each occupies its own cell, matching what a terminal would show.
        for scalar in decoded.unicodeScalars {
            writeCell(Array(String(scalar).utf8))
        }
    }

    /// Publish a sequence that never finished arriving.
    private mutating func flushPartialScalar() {
        guard !partialScalar.isEmpty else { return }
        partialScalar.removeAll(keepingCapacity: true)
        writeCell(Self.replacementCharacterBytes)
    }

    /// Total length in bytes of the UTF-8 sequence a lead byte introduces, or `nil`
    /// if the byte cannot start one.
    private static func utf8SequenceLength(leadByte: UInt8) -> Int? {
        switch leadByte {
        case 0x00...0x7F: 1
        case 0xC0...0xDF: 2
        case 0xE0...0xEF: 3
        case 0xF0...0xF7: 4
        default: nil        // 0x80...0xBF are continuation bytes; 0xF8+ are invalid
        }
    }
}
