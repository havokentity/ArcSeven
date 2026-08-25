// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// The column model: which columns a panel gets, how wide they start, and what each
// cell actually says.
//
// Cell rendering is where 7zFM's behaviour is least obvious, so most of these tests
// pin down a *blank* result. A folder with no size, a ".." row, a property the format
// never emitted — all three render as "" rather than "0", "-" or "n/a", because in a
// column of numbers a placeholder reads as data.

import Foundation
import Testing
import ArchiveCore
@testable import FMKit

@Suite("Column model")
struct ColumnModelTests {
    // MARK: Fixtures

    private func file(
        _ name: String,
        size: UInt64? = nil,
        packedSize: UInt64? = nil,
        crc: UInt32? = nil,
        encrypted: Bool = false,
        properties: [PropID: String] = [:]
    ) -> FolderItem {
        let entry = ArchiveEntry(
            path: name,
            isDirectory: false,
            size: size,
            packedSize: packedSize,
            crc: crc,
            isEncrypted: encrypted,
            properties: properties
        )
        return FolderItem(
            path: name, name: name, isNavigable: false, isDirectory: false,
            properties: properties, entry: entry
        )
    }

    private func folder(
        _ name: String,
        properties: [PropID: String] = [:],
        encrypted: Bool = false
    ) -> FolderItem {
        let entry = ArchiveEntry(
            path: name,
            isDirectory: true,
            // A size on a folder entry is deliberate: some handlers emit one, and the
            // Size column must still stay blank.
            size: 4096,
            isEncrypted: encrypted,
            properties: properties
        )
        return FolderItem(
            path: name, name: name, isNavigable: true, isDirectory: true,
            properties: properties, entry: entry
        )
    }

    private var parentRow: FolderItem {
        FolderItem(path: "..", name: "..", isNavigable: true, isDirectory: true)
    }

    /// Every column 7zFM can show inside a `.7z`, in canonical order.
    private let archiveColumns: [PropID] = [
        .name, .size, .packedSize, .modified, .created, .accessed,
        .attributes, .crc, .method, .block, .encrypted,
    ]

    // MARK: Building the default set

    @Test("One column per advertised property, in the order given")
    func columnsFollowAvailableOrder() {
        let model = ColumnModel(available: archiveColumns)
        #expect(model.columns.map(\.property) == archiveColumns)
        #expect(model.columns.count == archiveColumns.count)
    }

    @Test("An empty property list yields no columns")
    func emptyAvailableYieldsNoColumns() {
        #expect(ColumnModel(available: []).columns.isEmpty)
    }

    @Test("Documented default widths")
    func defaultWidths() {
        let expected: [(PropID, Double)] = [
            (.name, 320),
            (.size, 100), (.packedSize, 100),
            (.modified, 150), (.created, 150), (.accessed, 150),
            (.attributes, 100),
            (.crc, 90),
            (.method, 140),
            (.block, 60),
            (.encrypted, 80),
        ]
        for (property, width) in expected {
            #expect(ColumnModel.defaultWidth(for: property) == width, "width of \(property.rawValue)")
        }
        // Anything not in the table — a format-specific property we have never seen —
        // gets the generic width rather than zero.
        #expect(ColumnModel.defaultWidth(for: .comment) == 110)
        #expect(ColumnModel.defaultWidth(for: PropID("Some Future Property")) == 110)
    }

    @Test("Sizes, CRC and Block right-align; everything else reads left")
    func defaultAlignments() {
        let trailing: [PropID] = [.size, .packedSize, .crc, .block]
        for property in trailing {
            #expect(
                ColumnModel.defaultAlignment(for: property) == .trailing,
                "alignment of \(property.rawValue)"
            )
        }

        let leading: [PropID] = [
            .name, .modified, .created, .accessed, .attributes, .method,
            .encrypted, .comment, .method, PropID("Some Future Property"),
        ]
        for property in leading {
            #expect(
                ColumnModel.defaultAlignment(for: property) == .leading,
                "alignment of \(property.rawValue)"
            )
        }
    }

    @Test("Built columns carry the default width and alignment for their property")
    func builtColumnsUseDefaults() {
        let model = ColumnModel(available: archiveColumns)
        for column in model.columns {
            #expect(column.width == ColumnModel.defaultWidth(for: column.property))
            #expect(column.alignment == ColumnModel.defaultAlignment(for: column.property))
        }

        // Spot-check the two extremes so a change to the table is visible here and not
        // only in `defaultWidths`.
        let name = model.columns.first { $0.property == .name }
        #expect(name?.width == 320)
        #expect(name?.alignment == .leading)

        let size = model.columns.first { $0.property == .size }
        #expect(size?.width == 100)
        #expect(size?.alignment == .trailing)
    }

    @Test("Header text is 7-Zip's own property name")
    func headerTitleMatchesPropertyName() {
        let model = ColumnModel(available: [.packedSize])
        #expect(model.columns.first?.title == "Packed Size")
    }

    // MARK: Rendering

    @Test("The Name column is the row's name")
    func nameColumnShowsName() {
        #expect(ColumnModel.displayText(for: file("readme.md"), column: .name) == "readme.md")
        #expect(ColumnModel.displayText(for: folder("docs"), column: .name) == "docs")
        // Even the ".." row keeps its name — that is the one thing it carries.
        #expect(ColumnModel.displayText(for: parentRow, column: .name) == "..")
    }

    @Test("The .. row is blank in every column but Name")
    func parentRowIsBlankEverywhereElse() {
        // Give the row values in every column; they must still not be drawn.
        var loaded = parentRow
        loaded.properties = [
            .size: "1024", .packedSize: "512", .attributes: "D....",
            .method: "LZMA2", .block: "0", .encrypted: "+",
        ]
        loaded.entry = ArchiveEntry(
            path: "..", isDirectory: false, size: 1024, crc: 0xDEAD_BEEF, isEncrypted: true
        )

        for column in archiveColumns where column != .name {
            #expect(
                ColumnModel.displayText(for: loaded, column: column).isEmpty,
                "\(column.rawValue) must be blank on the parent row"
            )
        }
    }

    @Test("A directory shows no size — blank, never 0")
    func directoryHasNoSize() {
        // The fixture's entry deliberately carries size 4096 and a Size property.
        let item = folder("docs", properties: [.size: "4096"])
        let text = ColumnModel.displayText(for: item, column: .size)
        #expect(text.isEmpty)
        #expect(text != "0")
    }

    @Test("Sizes render as grouped digit counts")
    func sizesRenderGrouped() {
        let item = file("big.bin", size: 1_048_576, packedSize: 262_144)
        #expect(ColumnModel.displayText(for: item, column: .size)
                == ColumnModel.groupedByteCount(1_048_576))
        #expect(ColumnModel.displayText(for: item, column: .packedSize)
                == ColumnModel.groupedByteCount(262_144))

        // A zero-byte file is a real size and does render, unlike a folder.
        #expect(ColumnModel.displayText(for: file("empty", size: 0), column: .size)
                == ColumnModel.groupedByteCount(0))
    }

    @Test("A missing size is blank, not a placeholder")
    func missingSizeIsBlank() {
        let item = file("unknown.bin")           // no size anywhere
        #expect(ColumnModel.displayText(for: item, column: .size).isEmpty)
        #expect(ColumnModel.displayText(for: item, column: .packedSize).isEmpty)
    }

    @Test("CRC is eight uppercase zero-padded hex digits")
    func crcIsPaddedHex() {
        #expect(ColumnModel.displayText(for: file("a", crc: 0x0000_00FF), column: .crc) == "000000FF")
        #expect(ColumnModel.displayText(for: file("b", crc: 0x0000_0000), column: .crc) == "00000000")
        #expect(ColumnModel.displayText(for: file("c", crc: 0xDEAD_BEEF), column: .crc) == "DEADBEEF")
        #expect(ColumnModel.displayText(for: file("d", crc: 0xFFFF_FFFF), column: .crc) == "FFFFFFFF")

        // Shape, independent of the value: always eight characters, always uppercase.
        let text = ColumnModel.displayText(for: file("e", crc: 0x0012_ABCD), column: .crc)
        #expect(text.count == 8)
        #expect(text == text.uppercased())
    }

    @Test("A row with no CRC falls back to the property bag, then to blank")
    func crcFallsBackWhenAbsent() {
        // No entry CRC, but the handler emitted the string form.
        let fromProperties = file("a", properties: [.crc: "1A2B3C4D"])
        #expect(ColumnModel.displayText(for: fromProperties, column: .crc) == "1A2B3C4D")

        #expect(ColumnModel.displayText(for: file("b"), column: .crc).isEmpty)
    }

    @Test("Encrypted shows + only for encrypted non-directories")
    func encryptedMarker() {
        #expect(ColumnModel.displayText(for: file("secret.txt", encrypted: true), column: .encrypted) == "+")
        #expect(ColumnModel.displayText(for: file("plain.txt"), column: .encrypted).isEmpty)

        // A folder entry is never marked, even when the handler says it is encrypted:
        // there is no member data to encrypt, and a "+" there is misleading.
        #expect(ColumnModel.displayText(for: folder("vault", encrypted: true), column: .encrypted).isEmpty)

        // A row with no archive entry at all (a plain disk file) cannot be encrypted.
        let diskRow = FolderItem(
            path: "/tmp/x.txt", name: "x.txt", isNavigable: false, isDirectory: false
        )
        #expect(ColumnModel.displayText(for: diskRow, column: .encrypted).isEmpty)
    }

    @Test("A property the format never emitted renders blank, not a placeholder")
    func missingValueIsBlank() {
        let item = file("plain.txt")
        for column in [PropID.attributes, .method, .block, .comment, .hostOS] {
            let text = ColumnModel.displayText(for: item, column: column)
            #expect(text.isEmpty, "\(column.rawValue) should be blank")
            #expect(text != "-")
            #expect(text != "n/a")
        }
    }

    @Test("An unknown property falls through to the property bag")
    func unknownPropertyReadsThePropertyBag() {
        let exotic = PropID("Volume Serial Number")
        let item = file("weird.img", properties: [exotic: "A1B2-C3D4", .method: "LZMA2:24"])

        // The point of a String-keyed PropID: a column for a property we have never
        // heard of still renders, because the bag is consulted by default.
        #expect(ColumnModel.displayText(for: item, column: exotic) == "A1B2-C3D4")
        #expect(ColumnModel.displayText(for: item, column: .method) == "LZMA2:24")
        #expect(ColumnModel.displayText(for: item, column: PropID("Never Emitted")).isEmpty)
    }

    @Test("A timestamp with no parsed date falls back to the raw string")
    func timestampFallsBackToRawString() {
        // No entry date, but the provider stashed the printed form. Better to show the
        // handler's own text than to blank a column that clearly has a value.
        let item = file("a", properties: [.modified: "2026-01-02 03:04:05"])
        #expect(ColumnModel.displayText(for: item, column: .modified) == "2026-01-02 03:04:05")
        #expect(ColumnModel.displayText(for: file("b"), column: .modified).isEmpty)
    }

    @Test("A parsed timestamp renders through the date formatter, not the raw string")
    func timestampPrefersTheParsedDate() {
        let when = Date(timeIntervalSince1970: 1_767_225_845)
        var entry = ArchiveEntry(path: "a", isDirectory: false)
        entry.modified = when
        let item = FolderItem(
            path: "a", name: "a", isNavigable: false, isDirectory: false,
            properties: [.modified: "RAW"], entry: entry
        )
        #expect(ColumnModel.displayText(for: item, column: .modified)
                == when.formatted(date: .numeric, time: .shortened))
    }

    // MARK: Byte counts

    /// The Size column is an exact grouped count, not "1.2 MB". Rounding makes the
    /// Size-vs-Packed-Size comparison — the whole point of the column pair — useless.
    ///
    /// Assertions are on digit content and length, never on the separator character:
    /// the grouping separator is locale-dependent and the test may run anywhere.
    @Test("Byte counts group their digits and never abbreviate")
    func groupedByteCountKeepsEveryDigit() {
        let text = ColumnModel.groupedByteCount(1_048_576)

        let digits = text.filter(\.isNumber)
        #expect(digits.count == 7)
        #expect(digits == 1_048_576.formatted(.number.grouping(.never)).filter(\.isNumber))

        // "1.2 MB" or "1 MiB" would carry letters. The Size column carries none.
        let hasLetters = text.contains(where: \.isLetter)
        #expect(!hasLetters)

        // Something was inserted between the digits — whatever this locale groups with.
        #expect(text.count > digits.count)
    }

    @Test("Small counts survive intact")
    func groupedByteCountOfSmallValues() {
        #expect(ColumnModel.groupedByteCount(0).filter(\.isNumber).count == 1)
        #expect(ColumnModel.groupedByteCount(0) == 0.formatted(.number.grouping(.automatic)))
        #expect(ColumnModel.groupedByteCount(999).filter(\.isNumber).count == 3)
    }

    @Test("A 64-bit count is not truncated or rounded")
    func groupedByteCountOfHugeValues() {
        let text = ColumnModel.groupedByteCount(UInt64.max)   // 18446744073709551615
        let digits = text.filter(\.isNumber)
        #expect(digits.count == 20)
        #expect(digits == UInt64.max.formatted(.number.grouping(.never)).filter(\.isNumber))
        let hasLetters = text.contains(where: \.isLetter)
        #expect(!hasLetters)
    }
}
