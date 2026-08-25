// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte

import Foundation

/// One member of an archive.
///
/// Engine-agnostic: the CLI engine builds these from `7zz l -slt` property bags,
/// and a future in-process engine would build them from `IInArchive::GetProperty`
/// `PROPVARIANT`s. The strongly-typed fields cover what every UI surface needs;
/// ``properties`` retains the complete, format-dependent bag so that the column
/// model can show handler-specific columns (`Host OS`, `Volume Index`, `Characteristics`, …)
/// without this type having to know about them.
public struct ArchiveEntry: Sendable, Hashable, Identifiable, Codable {
    /// Stable identity within a listing: the path is unique inside a well-formed
    /// archive. (Malformed archives can repeat a path; the listing records that as
    /// a warning rather than silently coalescing rows.)
    public var id: String { path }

    /// The member path, `/`-separated, relative to the archive root.
    ///
    /// 7-Zip emits `\` separators only for archives created on Windows by handlers
    /// that store them literally; the CLI engine normalises those to `/` at parse
    /// time so that path arithmetic in the panes has exactly one convention.
    public var path: String

    /// `true` when the member is a directory.
    ///
    /// Derived from the `Folder` property where the handler advertises it (zip),
    /// and otherwise from the `D` flag in ``attributes`` (7z, which does not emit
    /// `Folder`). See res_3 §4a.4.
    public var isDirectory: Bool

    /// Uncompressed size in bytes, or `nil` when the handler does not report one.
    public var size: UInt64?

    /// Compressed size in bytes.
    ///
    /// `nil` is normal and not an error: in a **solid** `.7z` block only the first
    /// member of the block carries a packed size, and every subsequent member emits
    /// an empty `Packed Size`.
    public var packedSize: UInt64?

    /// Last-modification timestamp.
    public var modified: Date?
    /// Creation timestamp, where the format stores one (zip, wim, …).
    public var created: Date?
    /// Last-access timestamp, where the format stores one.
    public var accessed: Date?

    /// Parsed attribute flags plus the raw attribute string.
    public var attributes: Attributes

    /// CRC-32 of the uncompressed data, when the format stores one.
    public var crc: UInt32?

    /// Codec chain for this member, e.g. `LZMA2:16`, `Store`, `LZMA2:12 7zAES:19`.
    ///
    /// The presence of `7zAES` here is the reliable tell that a member is
    /// body-encrypted, and matches ``isEncrypted``.
    public var method: String?

    /// `true` when this member's data is encrypted.
    ///
    /// Note that a *header*-encrypted archive cannot be listed at all without the
    /// password, so a listing that reports `isEncrypted == false` for everything is
    /// only meaningful once the listing itself succeeded — see
    /// ``ArchiveListing/isHeaderEncrypted``.
    public var isEncrypted: Bool

    /// Index of the solid block this member lives in (`.7z` only).
    ///
    /// Members sharing a block index must be decoded together, which is why
    /// extracting one file from the middle of a large solid archive is slow.
    public var blockIndex: Int?

    /// Target of a symbolic link, when the member is one and the format stored it.
    public var symlinkTarget: String?

    /// Originating operating system as the format records it (`Unix`, `FAT`, `NTFS`, …).
    public var hostOS: String?

    /// Per-member comment (zip stores one per entry).
    public var comment: String?

    /// The complete property bag exactly as the engine produced it.
    ///
    /// Values are unparsed strings — including empty strings, which mean
    /// "the handler emitted this key with no value", a different thing from
    /// "the handler did not emit this key at all".
    public var properties: [PropID: String]

    public init(
        path: String,
        isDirectory: Bool = false,
        size: UInt64? = nil,
        packedSize: UInt64? = nil,
        modified: Date? = nil,
        created: Date? = nil,
        accessed: Date? = nil,
        attributes: Attributes = Attributes(),
        crc: UInt32? = nil,
        method: String? = nil,
        isEncrypted: Bool = false,
        blockIndex: Int? = nil,
        symlinkTarget: String? = nil,
        hostOS: String? = nil,
        comment: String? = nil,
        properties: [PropID: String] = [:]
    ) {
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.packedSize = packedSize
        self.modified = modified
        self.created = created
        self.accessed = accessed
        self.attributes = attributes
        self.crc = crc
        self.method = method
        self.isEncrypted = isEncrypted
        self.blockIndex = blockIndex
        self.symlinkTarget = symlinkTarget
        self.hostOS = hostOS
        self.comment = comment
        self.properties = properties
    }
}

// MARK: - Derived conveniences

extension ArchiveEntry {
    /// The last path component.
    public var name: String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    /// Everything before the last path component, or `""` at the archive root.
    public var parentPath: String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[path.startIndex..<slash])
    }

    /// Lowercased filename extension without the dot, or `""`.
    public var pathExtension: String {
        let n = name
        guard let dot = n.lastIndex(of: "."), dot != n.startIndex else { return "" }
        return String(n[n.index(after: dot)...]).lowercased()
    }

    /// `true` when the member is a symbolic link.
    public var isSymbolicLink: Bool {
        attributes.isSymbolicLink || symlinkTarget != nil
    }

    /// Compression ratio in `0...1`, or `nil` when either size is unknown, the
    /// member is empty, or the packed size belongs to a shared solid block.
    public var compressionRatio: Double? {
        guard let size, let packedSize, size > 0 else { return nil }
        return Double(packedSize) / Double(size)
    }

    /// Look up an arbitrary property, including ones without a typed field.
    public subscript(property: PropID) -> String? {
        properties[property]
    }
}

// MARK: - Attributes

extension ArchiveEntry {
    /// A parsed 7-Zip attribute string.
    ///
    /// `7zz l -slt` renders attributes as up to two space-separated fields:
    ///
    /// ```text
    /// Attributes = D drwxr-xr-x      // DOS flag letters, then a POSIX mode string
    /// Attributes = A -rw-r--r--
    /// Attributes =  -rw-r--r--       // no DOS flags at all: note the double space
    /// Attributes = A                 // DOS flags only (archive made on Windows)
    /// ```
    ///
    /// Both fields are optional and either may be absent, so the parser is
    /// positional only in the sense that DOS letters precede the mode string; it
    /// identifies each token by shape, never by index.
    public struct Attributes: Sendable, Hashable, Codable {
        /// DOS/Windows attribute letters as 7-Zip prints them.
        public struct DOSFlags: OptionSet, Sendable, Hashable, Codable {
            public let rawValue: UInt32
            public init(rawValue: UInt32) { self.rawValue = rawValue }

            public static let readOnly  = Self(rawValue: 1 << 0) // R
            public static let hidden    = Self(rawValue: 1 << 1) // H
            public static let system    = Self(rawValue: 1 << 2) // S
            public static let directory = Self(rawValue: 1 << 3) // D
            public static let archive   = Self(rawValue: 1 << 4) // A
        }

        /// The unmodified `Attributes` value, kept for the Properties inspector.
        public var raw: String
        /// Parsed DOS attribute letters.
        public var dos: DOSFlags
        /// POSIX permission bits (`0o755`, …) when a mode string was present.
        public var posixMode: UInt16?
        /// The POSIX file-type character (`d`, `-`, `l`, `p`, `s`, `c`, `b`) when present.
        public var posixFileType: Character?

        // MARK: Codable
        //
        // `Character` is not `Codable`, and synthesised conformance therefore fails.
        // Every field here is derived from `raw` by `parse(_:)`, so the archived form
        // is just that string and decoding re-derives the rest. Lossless, and it keeps
        // the on-disk representation legible.
        private enum CodingKeys: String, CodingKey { case raw }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self = Self.parse(try container.decode(String.self, forKey: .raw))
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(raw, forKey: .raw)
        }

        public init(
            raw: String = "",
            dos: DOSFlags = [],
            posixMode: UInt16? = nil,
            posixFileType: Character? = nil
        ) {
            self.raw = raw
            self.dos = dos
            self.posixMode = posixMode
            self.posixFileType = posixFileType
        }

        /// `true` when either the DOS `D` flag or a leading `d` in the mode string
        /// marks this member as a directory.
        public var isDirectory: Bool {
            dos.contains(.directory) || posixFileType == "d"
        }

        /// `true` when the POSIX mode string marks this member as a symbolic link.
        public var isSymbolicLink: Bool { posixFileType == "l" }

        /// Parse an `Attributes` value. Never fails: unrecognised shapes are kept
        /// verbatim in ``raw`` with no flags set.
        public static func parse(_ raw: String) -> Self {
            var result = Self(raw: raw)
            for token in raw.split(separator: " ", omittingEmptySubsequences: true) {
                if let mode = parsePOSIXModeString(token) {
                    result.posixFileType = token.first
                    result.posixMode = mode
                } else if token.allSatisfy({ "RHSDA".contains($0) }) {
                    for character in token {
                        switch character {
                        case "R": result.dos.insert(.readOnly)
                        case "H": result.dos.insert(.hidden)
                        case "S": result.dos.insert(.system)
                        case "D": result.dos.insert(.directory)
                        case "A": result.dos.insert(.archive)
                        default: break
                        }
                    }
                }
            }
            return result
        }

        /// Decode a ten-character `drwxr-xr-x`-style mode string into permission
        /// bits, honouring the `s`/`S`/`t`/`T` setuid/setgid/sticky spellings.
        /// Returns `nil` for anything that is not a mode string.
        private static func parsePOSIXModeString(_ token: Substring) -> UInt16? {
            guard token.count == 10 else { return nil }
            let characters = Array(token)
            guard "-dlpscb".contains(characters[0]) else { return nil }

            var mode: UInt16 = 0
            // Three rwx triples, most-significant first.
            for triple in 0..<3 {
                let base = 1 + triple * 3
                let shift = UInt16(6 - triple * 3)
                guard characters[base] == "r" || characters[base] == "-",
                      characters[base + 1] == "w" || characters[base + 1] == "-"
                else { return nil }
                if characters[base] == "r" { mode |= 0o4 << shift }
                if characters[base + 1] == "w" { mode |= 0o2 << shift }

                switch characters[base + 2] {
                case "x":
                    mode |= 0o1 << shift
                case "-":
                    break
                case "s" where triple == 0:
                    mode |= 0o1 << shift; mode |= 0o4000
                case "S" where triple == 0:
                    mode |= 0o4000
                case "s" where triple == 1:
                    mode |= 0o1 << shift; mode |= 0o2000
                case "S" where triple == 1:
                    mode |= 0o2000
                case "t" where triple == 2:
                    mode |= 0o1 << shift; mode |= 0o1000
                case "T" where triple == 2:
                    mode |= 0o1000
                default:
                    return nil
                }
            }
            return mode
        }
    }
}

// MARK: - Building an entry from a property bag

extension ArchiveEntry {
    /// Build an entry from an engine property bag.
    ///
    /// Returns `nil` when the bag has no usable `Path` — a bag without a path is
    /// not an entry, it is corruption, and the caller records it as a warning.
    ///
    /// - Parameters:
    ///   - properties: raw, unparsed key/value pairs.
    ///   - timeZone: the zone the engine's timestamps are expressed in. `7zz l -slt`
    ///     prints wall-clock local time with no zone marker (res_3 §4a.4), so this
    ///     defaults to the current zone; pass `.gmt` when the engine was asked for
    ///     UTC timestamps.
    public init?(properties: [PropID: String], timeZone: TimeZone = .current) {
        func text(_ key: PropID) -> String? {
            guard let value = properties[key], !value.isEmpty else { return nil }
            return value
        }
        func number(_ key: PropID) -> UInt64? {
            guard let value = text(key) else { return nil }
            return UInt64(value.trimmingCharacters(in: .whitespaces))
        }
        // `+`/`-` property flags. A missing or unrecognised value is not the
        // handler saying "false", it is the handler saying nothing, so the caller
        // supplies what to believe instead. `@autoclosure` keeps that fallback as
        // lazy as the `??` it replaces.
        func flag(_ key: PropID, or fallback: @autoclosure () -> Bool) -> Bool {
            guard let value = text(key) else { return fallback() }
            switch value {
            case "+": return true
            case "-": return false
            default: return fallback()
            }
        }
        func date(_ key: PropID) -> Date? {
            guard let value = text(key) else { return nil }
            return SevenZipTimestamp.parse(value, timeZone: timeZone)
        }

        guard let rawPath = properties[PropID.path] ?? properties[PropID.name],
              !rawPath.isEmpty
        else { return nil }

        let attributes = Attributes.parse(properties[PropID.attributes] ?? "")

        // `Folder = +` is authoritative where the handler emits it (zip). The 7z
        // handler does not, so fall back to the `D` attribute flag (res_3 §4a.4).
        let isDirectory = flag(PropID.isFolder, or: attributes.isDirectory)

        var crcValue: UInt32?
        if let raw = text(PropID.crc) {
            crcValue = UInt32(raw.trimmingCharacters(in: .whitespaces), radix: 16)
        }

        var block: Int?
        if let raw = text(PropID.block) {
            block = Int(raw.trimmingCharacters(in: .whitespaces))
        }

        let method = text(PropID.method)
        // A member is encrypted when the handler says so; when it stays silent, a
        // `7zAES` stage in the codec chain says so just as reliably.
        let encrypted = flag(
            PropID.encrypted,
            or: method.map { $0.localizedCaseInsensitiveContains("AES") } ?? false
        )

        self.init(
            path: Self.normalisePath(rawPath),
            isDirectory: isDirectory,
            size: number(PropID.size),
            packedSize: number(PropID.packedSize),
            modified: date(PropID.modified),
            created: date(PropID.created),
            accessed: date(PropID.accessed),
            attributes: attributes,
            crc: crcValue,
            method: method,
            isEncrypted: encrypted,
            blockIndex: block,
            symlinkTarget: text(PropID.symbolicLink) ?? text(PropID.ntReparse),
            hostOS: text(PropID.hostOS),
            comment: text(PropID.comment),
            properties: properties
        )
    }

    /// Normalise a stored path to the one separator convention the app uses.
    ///
    /// Some handlers (notably older zip writers) store `\` separators. We convert
    /// them so that every path comparison in FMKit can assume `/`. A literal `\`
    /// in a POSIX filename is legal but vanishingly rare inside an archive, and
    /// preserving it would cost us correct navigation for the common case.
    static func normalisePath(_ raw: String) -> String {
        raw.contains("\\") ? raw.replacingOccurrences(of: "\\", with: "/") : raw
    }
}

// MARK: - Timestamp parsing

/// Parser for the timestamp format `7zz` prints.
///
/// Deliberately hand-rolled rather than `DateFormatter`-based: this runs once per
/// property per entry (tens of thousands of times for a large archive), and it must
/// be immune to the user's locale, calendar and 12-hour-clock settings.
public enum SevenZipTimestamp {
    /// Parse `YYYY-MM-DD HH:MM:SS`, optionally followed by `.` and fractional
    /// digits, optionally followed by `Z` or `±HH[:MM]`.
    ///
    /// - Parameters:
    ///   - string: the raw property value.
    ///   - timeZone: zone to interpret the value in when it carries no explicit
    ///     offset.
    /// - Returns: the instant, or `nil` if the string is not a timestamp.
    public static func parse(_ string: String, timeZone: TimeZone = .current) -> Date? {
        let scalars = Array(string.trimmingCharacters(in: .whitespaces).utf8)
        // Minimum shape is "YYYY-MM-DD HH:MM:SS" = 19 bytes.
        guard scalars.count >= 19 else { return nil }

        func digits(_ range: Range<Int>) -> Int? {
            var value = 0
            for index in range {
                let byte = scalars[index]
                guard byte >= 0x30, byte <= 0x39 else { return nil }
                value = value * 10 + Int(byte - 0x30)
            }
            return value
        }

        guard scalars[4] == UInt8(ascii: "-"), scalars[7] == UInt8(ascii: "-"),
              scalars[10] == UInt8(ascii: " ") || scalars[10] == UInt8(ascii: "T"),
              scalars[13] == UInt8(ascii: ":"), scalars[16] == UInt8(ascii: ":"),
              let year = digits(0..<4), let month = digits(5..<7), let day = digits(8..<10),
              let hour = digits(11..<13), let minute = digits(14..<16), let second = digits(17..<19),
              (1...12).contains(month), (1...31).contains(day),
              hour < 24, minute < 60, second <= 60
        else { return nil }

        var fractional = 0.0
        var cursor = 19
        if cursor < scalars.count, scalars[cursor] == UInt8(ascii: ".") {
            cursor += 1
            var scale = 0.1
            while cursor < scalars.count, scalars[cursor] >= 0x30, scalars[cursor] <= 0x39 {
                fractional += Double(scalars[cursor] - 0x30) * scale
                scale /= 10
                cursor += 1
            }
        }

        let naive = Double(secondsFromCivilUTC(year: year, month: month, day: day,
                                               hour: hour, minute: minute, second: second))

        // Skip whitespace before any zone marker.
        while cursor < scalars.count, scalars[cursor] == UInt8(ascii: " ") { cursor += 1 }

        var offsetSeconds: Int
        if cursor < scalars.count, scalars[cursor] == UInt8(ascii: "Z") {
            offsetSeconds = 0
        } else if cursor < scalars.count,
                  scalars[cursor] == UInt8(ascii: "+") || scalars[cursor] == UInt8(ascii: "-"),
                  cursor + 2 < scalars.count,
                  let offsetHours = digits((cursor + 1)..<(cursor + 3)) {
            var minutes = 0
            var minuteStart = cursor + 3
            if minuteStart < scalars.count, scalars[minuteStart] == UInt8(ascii: ":") {
                minuteStart += 1
            }
            if minuteStart + 1 < scalars.count, let parsed = digits(minuteStart..<(minuteStart + 2)) {
                minutes = parsed
            }
            let magnitude = offsetHours * 3600 + minutes * 60
            offsetSeconds = scalars[cursor] == UInt8(ascii: "-") ? -magnitude : magnitude
        } else {
            // No explicit zone: interpret in `timeZone`. Resolving the offset needs
            // an instant, and the instant needs the offset, so probe with the naive
            // value first. This is exact except inside a DST transition, where the
            // wall-clock time is genuinely ambiguous or non-existent and no reading
            // is more correct than another.
            offsetSeconds = timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: naive))
        }

        return Date(timeIntervalSince1970: naive - Double(offsetSeconds) + fractional)
    }

    /// Days-from-civil, after Howard Hinnant's public-domain `days_from_civil`
    /// algorithm: a branch-free proleptic-Gregorian date-to-epoch conversion.
    private static func secondsFromCivilUTC(
        year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int
    ) -> Int {
        let adjustedYear = year - (month <= 2 ? 1 : 0)
        let era = (adjustedYear >= 0 ? adjustedYear : adjustedYear - 399) / 400
        let yearOfEra = adjustedYear - era * 400                                  // 0...399
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1  // 0...365
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468
        return days * 86_400 + hour * 3600 + minute * 60 + second
    }
}
