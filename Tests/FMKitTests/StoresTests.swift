// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte
//
// The persistence stores.
//
// Every test runs against a throwaway `UserDefaults` suite named after a fresh UUID
// and tears the whole persistent domain down afterwards, so a test run never reads or
// writes the real `com.havokentity.ArcSeven` domain — and so two tests can never see
// each other's history, favourites or column layout.

import Foundation
import Testing
import ArchiveCore
@testable import FMKit

/// Scaffolding shared by the three store suites below.
enum ThrowawayDefaults {
    /// Prefix every throwaway suite shares, so the sweep below can recognise its own
    /// litter and nothing else.
    static let suitePrefix = "com.havokentity.ArcSeven.StoresTests."

    /// Delete the empty suite plists left behind by EARLIER test runs.
    ///
    /// `removePersistentDomain` empties a domain immediately, which is what
    /// correctness needs — but `cfprefsd` has already been told the suite exists, and
    /// it writes the now-empty `<suite>.plist` into `~/Library/Preferences` roughly
    /// eight seconds AFTER the test process has exited. That is measured, not assumed,
    /// and it means no `defer`, no `atexit` and no `synchronize()` can win the race:
    /// the file is created after the only code we control has stopped running. Left
    /// alone it is 28 junk files per `swift test`, forever.
    ///
    /// Sweeping at the start of the next run is the one deterministic moment — by then
    /// the previous run's writes have long since landed — and it bounds the residue to
    /// a single run instead of letting it grow without limit. Files from THIS run
    /// cannot be caught by it, and no live suite can be harmed by it, precisely
    /// because of that eight-second delay.
    ///
    /// A `static let` so it runs exactly once per process, lazily and thread-safely,
    /// however many tests swift-testing decides to run in parallel.
    static let sweepStaleSuites: Void = {
        let manager = FileManager.default
        let preferences = manager.homeDirectoryForCurrentUser
            .appending(path: "Library/Preferences")
        let names = (try? manager.contentsOfDirectory(atPath: preferences.path())) ?? []
        for name in names where name.hasPrefix(suitePrefix) && name.hasSuffix(".plist") {
            try? manager.removeItem(at: preferences.appending(path: name))
        }
    }()
}

/// Conforming is the whole implementation: it hands a suite `withDefaults`.
protocol UsesThrowawayDefaults {}

extension UsesThrowawayDefaults {
    /// Run `body` against a private, empty defaults domain that is emptied on exit.
    ///
    /// The UUID suite name is what keeps tests — which swift-testing runs in
    /// parallel — from seeing each other's writes, and what guarantees none of them
    /// touches the real `com.havokentity.ArcSeven` domain.
    func withDefaults<T>(_ body: (UserDefaults) throws -> T) throws -> T {
        _ = ThrowawayDefaults.sweepStaleSuites
        let suiteName = "\(ThrowawayDefaults.suitePrefix)\(UUID().uuidString)"
        let defaults = try #require(
            UserDefaults(suiteName: suiteName),
            "the suite name must be usable as a defaults domain"
        )
        // Best-effort: a teardown failure must not fail the test that just passed.
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            defaults.synchronize()
        }
        return try body(defaults)
    }
}

@Suite("Folder history store")
struct FolderHistoryStoreTests: UsesThrowawayDefaults {
    @Test("History is most-recent-first")
    func historyOrdering() throws {
        try withDefaults { defaults in
            let store = FolderHistoryStore(defaults: defaults)
            store.record("/Users/me/one")
            store.record("/Users/me/two")
            store.record("/Users/me/three")

            #expect(store.recent() == ["/Users/me/three", "/Users/me/two", "/Users/me/one"])
        }
    }

    /// Re-visiting a folder must MOVE its row to the top, not append a second one.
    @Test("Re-visiting a folder promotes it instead of duplicating it")
    func historyPromotesOnRevisit() throws {
        try withDefaults { defaults in
            let store = FolderHistoryStore(defaults: defaults)
            store.record("/a")
            store.record("/b")
            store.record("/a")

            #expect(store.recent() == ["/a", "/b"])
        }
    }

    /// APFS is case-insensitive by default, so these are one folder and must occupy
    /// one row — with the casing the user navigated with most recently.
    @Test("De-duplication ignores case, and the newest spelling wins")
    func historyDeduplicatesCaseInsensitively() throws {
        try withDefaults { defaults in
            let store = FolderHistoryStore(defaults: defaults)
            store.record("/Users/Me/Downloads")
            store.record("/users/me/downloads")

            #expect(store.recent() == ["/users/me/downloads"])
        }
    }

    /// A path typed into the path bar arrives composed; one read off HFS+ arrives
    /// decomposed. They name the same directory.
    @Test("De-duplication folds Unicode composition and a trailing separator")
    func historyNormalisesPaths() throws {
        try withDefaults { defaults in
            let store = FolderHistoryStore(defaults: defaults)
            let composed = "/Users/me/Caf\u{00E9}"      // é as one scalar
            let decomposed = "/Users/me/Cafe\u{0301}/"  // e + combining acute, plus a trailing /
            store.record(composed)
            store.record(decomposed)

            #expect(store.recent().count == 1)
            #expect(store.contains(composed))
        }
    }

    @Test("History is bounded and drops the oldest entry")
    func historyIsBounded() throws {
        try withDefaults { defaults in
            let store = FolderHistoryStore(defaults: defaults, limit: 4)
            for index in 1...10 { store.record("/folder\(index)") }

            let recent = store.recent()
            #expect(recent.count == 4)
            #expect(recent == ["/folder10", "/folder9", "/folder8", "/folder7"])
            #expect(!store.contains("/folder1"))
        }
    }

    @Test("The default bound is 32")
    func historyDefaultBound() throws {
        try withDefaults { defaults in
            let store = FolderHistoryStore(defaults: defaults)
            for index in 1...50 { store.record("/folder\(index)") }

            #expect(FolderHistoryStore.defaultLimit == 32)
            #expect(store.recent().count == 32)
            #expect(store.recent(limit: 3) == ["/folder50", "/folder49", "/folder48"])
            #expect(store.recent(limit: 0).isEmpty)
        }
    }

    @Test("Blank paths are not recorded")
    func historyIgnoresBlankPaths() throws {
        try withDefaults { defaults in
            let store = FolderHistoryStore(defaults: defaults)
            store.record("")
            store.record("   ")
            store.record("\n")

            #expect(store.recent().isEmpty)
        }
    }

    @Test("History survives a new store over the same defaults, and clear() empties it")
    func historyPersistsAndClears() throws {
        try withDefaults { defaults in
            let writer = FolderHistoryStore(defaults: defaults)
            writer.record("/Users/me/src.7z/docs")

            let reader = FolderHistoryStore(defaults: defaults)
            #expect(reader.recent() == ["/Users/me/src.7z/docs"])

            reader.clear()
            #expect(FolderHistoryStore(defaults: defaults).recent().isEmpty)
            // clear() removes the key rather than storing an empty array.
            #expect(defaults.object(forKey: FolderHistoryStore.defaultsKey) == nil)
        }
    }

    @Test("A hand-edited domain holding non-strings does not take the history down")
    func historyToleratesJunk() throws {
        try withDefaults { defaults in
            defaults.set([42, "/real/path", ""] as [Any], forKey: FolderHistoryStore.defaultsKey)
            let store = FolderHistoryStore(defaults: defaults)

            #expect(store.recent() == ["/real/path"])
        }
    }
}

@Suite("Favourites store")
struct FavouritesStoreTests: UsesThrowawayDefaults {
    @Test("There are exactly ten slots, empty until set")
    func favouritesHaveTenSlots() throws {
        try withDefaults { defaults in
            let store = FavoritesStore(defaults: defaults)

            #expect(FavoritesStore.slotCount == 10)
            #expect(store.all().count == 10)
            #expect(store.all().allSatisfy { $0 == nil })
            #expect(store.isEmpty)
        }
    }

    @Test("A slot round-trips and does not disturb its neighbours")
    func favouritesRoundTrip() throws {
        try withDefaults { defaults in
            let store = FavoritesStore(defaults: defaults)
            store.set("/Users/me/Projects", at: 0)
            store.set("/Volumes/Backup", at: 9)

            #expect(store.path(at: 0) == "/Users/me/Projects")
            #expect(store.path(at: 9) == "/Volumes/Backup")
            #expect(store.path(at: 4) == nil)
            #expect(store.all().compactMap { $0 }.count == 2)
            #expect(!store.isEmpty)
        }
    }

    /// The index IS the identity of a favourite: clearing slot 2 must not renumber
    /// slot 5, or the user's `⌃⌥6` starts opening someone else's folder.
    @Test("Clearing a slot leaves a hole rather than renumbering")
    func favouritesClearLeavesAHole() throws {
        try withDefaults { defaults in
            let store = FavoritesStore(defaults: defaults)
            store.set("/two", at: 2)
            store.set("/five", at: 5)

            store.set(nil, at: 2)

            #expect(store.path(at: 2) == nil)
            #expect(store.path(at: 5) == "/five")
            #expect(store.all().count == 10)
        }
    }

    @Test("An all-whitespace path clears the slot rather than storing blanks")
    func favouritesTreatBlankAsEmpty() throws {
        try withDefaults { defaults in
            let store = FavoritesStore(defaults: defaults)
            store.set("/something", at: 3)
            store.set("   ", at: 3)

            #expect(store.path(at: 3) == nil)
        }
    }

    @Test("Out-of-range slots are rejected and change nothing", arguments: [-1, 10, 99, Int.min, Int.max])
    func favouritesRejectOutOfRangeSlots(slot: Int) throws {
        try withDefaults { defaults in
            let store = FavoritesStore(defaults: defaults)
            store.set("/inside", at: 4)

            #expect(store.set("/outside", at: slot) == false)
            #expect(store.path(at: slot) == nil)
            #expect(store.all().compactMap { $0 } == ["/inside"])
        }
    }

    /// There is no `10` key, so the tenth favourite is bound to `0`.
    @Test("Keyboard digits map onto slots with 0 meaning the tenth")
    func favouritesKeyboardDigitMapping() {
        #expect(FavoritesStore.slot(forKeyboardDigit: 1) == 0)
        #expect(FavoritesStore.slot(forKeyboardDigit: 9) == 8)
        #expect(FavoritesStore.slot(forKeyboardDigit: 0) == 9)
        #expect(FavoritesStore.slot(forKeyboardDigit: 10) == nil)
        #expect(FavoritesStore.slot(forKeyboardDigit: -1) == nil)
    }

    @Test("Favourites persist and clear() empties every slot")
    func favouritesPersistAndClear() throws {
        try withDefaults { defaults in
            FavoritesStore(defaults: defaults).set("/kept", at: 7)
            #expect(FavoritesStore(defaults: defaults).path(at: 7) == "/kept")

            FavoritesStore(defaults: defaults).clear()
            let store = FavoritesStore(defaults: defaults)
            #expect(store.isEmpty)
            #expect(store.all().count == 10)
        }
    }

    /// A short or junk-laden array is what a partial migration or a `defaults write`
    /// leaves behind; it must widen back to ten slots without losing what is there.
    @Test("A short stored array is padded back out to ten slots")
    func favouritesPadShortArrays() throws {
        try withDefaults { defaults in
            defaults.set(["/zero", "", "/two"], forKey: FavoritesStore.defaultsKey)
            let store = FavoritesStore(defaults: defaults)

            #expect(store.all().count == 10)
            #expect(store.path(at: 0) == "/zero")
            #expect(store.path(at: 1) == nil)
            #expect(store.path(at: 2) == "/two")
            #expect(store.path(at: 9) == nil)
        }
    }
}

@Suite("Panel preferences store")
struct PanelPreferencesStoreTests: UsesThrowawayDefaults {
    private func diskColumns() -> [PanelColumn] {
        [
            PanelColumn(property: .name, width: 260, alignment: .leading),
            PanelColumn(property: .size, width: 100, alignment: .trailing),
            PanelColumn(property: .modified, width: 150, alignment: .leading),
        ]
    }

    /// An archive interior has Packed Size; a disk folder has no such column at all.
    private func archiveColumns() -> [PanelColumn] {
        [
            PanelColumn(property: .name, width: 400, alignment: .leading),
            PanelColumn(property: .size, width: 110, alignment: .trailing),
            PanelColumn(property: .packedSize, width: 110, alignment: .trailing),
            PanelColumn(property: .crc, width: 90, alignment: .trailing),
        ]
    }

    @Test("Nothing is remembered until something is set")
    func panelPreferencesStartEmpty() throws {
        try withDefaults { defaults in
            let store = PanelPreferences(defaults: defaults)
            #expect(store.columns(for: .fileSystem) == nil)
            #expect(store.sort(for: .archive) == nil)
        }
    }

    @Test("Columns round-trip with their order, widths and alignment intact")
    func panelColumnsRoundTrip() throws {
        try withDefaults { defaults in
            let store = PanelPreferences(defaults: defaults)
            store.setColumns(archiveColumns(), for: .archive)

            let restored = try #require(PanelPreferences(defaults: defaults).columns(for: .archive))
            #expect(restored == archiveColumns())
            #expect(restored.map(\.property) == [.name, .size, .packedSize, .crc])
            #expect(restored[0].width == 400)
            #expect(restored[2].alignment == .trailing)
        }
    }

    /// The whole reason this store is keyed per kind: a disk folder and an archive
    /// interior do not even have the same columns available.
    @Test("Each folder kind keeps its own layout")
    func panelColumnsAreKeyedPerKind() throws {
        try withDefaults { defaults in
            let store = PanelPreferences(defaults: defaults)
            store.setColumns(diskColumns(), for: .fileSystem)
            store.setColumns(archiveColumns(), for: .archive)

            #expect(store.columns(for: .fileSystem) == diskColumns())
            #expect(store.columns(for: .archive) == archiveColumns())
            #expect(store.columns(for: .volumes) == nil)

            // A disk folder has no Packed Size column; an archive interior does.
            let disk = try #require(store.columns(for: .fileSystem)).map(\.property)
            let archive = try #require(store.columns(for: .archive)).map(\.property)
            #expect(!disk.contains(.packedSize))
            #expect(archive.contains(.packedSize))
            #expect(store.storageKey(for: .archive) == "FM.Columns.archive")
        }
    }

    @Test("Sort descriptors round-trip per kind, in both directions")
    func panelSortRoundTrips() throws {
        try withDefaults { defaults in
            let store = PanelPreferences(defaults: defaults)
            store.setSort(SortDescriptor(column: .modified, direction: .descending), for: .fileSystem)
            store.setSort(SortDescriptor(column: .packedSize, direction: .ascending), for: .archive)

            let reader = PanelPreferences(defaults: defaults)
            #expect(reader.sort(for: .fileSystem) == SortDescriptor(column: .modified, direction: .descending))
            #expect(reader.sort(for: .archive) == SortDescriptor(column: .packedSize, direction: .ascending))
            #expect(reader.sort(for: .volumes) == nil)
        }
    }

    /// Columns and sort share one stored blob per kind, exactly as they share one
    /// registry subkey upstream, so each setter has to leave the other half alone.
    @Test("Setting columns does not disturb the stored sort, and vice versa")
    func panelColumnsAndSortAreIndependent() throws {
        try withDefaults { defaults in
            let store = PanelPreferences(defaults: defaults)
            store.setSort(SortDescriptor(column: .size, direction: .descending), for: .archive)
            store.setColumns(archiveColumns(), for: .archive)

            #expect(store.sort(for: .archive) == SortDescriptor(column: .size, direction: .descending))
            #expect(store.columns(for: .archive) == archiveColumns())

            store.setColumns(nil, for: .archive)
            #expect(store.columns(for: .archive) == nil)
            #expect(store.sort(for: .archive) == SortDescriptor(column: .size, direction: .descending))

            store.setSort(nil, for: .archive)
            #expect(store.sort(for: .archive) == nil)
        }
    }

    /// "No opinion stored" and "the user hid everything" are different states.
    @Test("An empty column array is a stored state, not a missing one")
    func panelEmptyColumnArrayIsStored() throws {
        try withDefaults { defaults in
            let store = PanelPreferences(defaults: defaults)
            store.setColumns([], for: .root)

            let restored = PanelPreferences(defaults: defaults).columns(for: .root)
            #expect(restored != nil)
            #expect(restored?.isEmpty == true)
        }
    }

    /// The raw value of a `PropID` is 7-Zip's own display name, so a property no
    /// build of ArcSeven has ever heard of still round-trips.
    @Test("An unknown property survives a round trip")
    func panelUnknownPropertyRoundTrips() throws {
        try withDefaults { defaults in
            let exotic = PropID("Quantum Flux")
            let store = PanelPreferences(defaults: defaults)
            store.setColumns([PanelColumn(property: exotic, width: 120, alignment: .leading)], for: .archive)
            store.setSort(SortDescriptor(column: exotic, direction: .descending), for: .archive)

            let reader = PanelPreferences(defaults: defaults)
            #expect(reader.columns(for: .archive)?.first?.property == exotic)
            #expect(reader.sort(for: .archive)?.column == exotic)
        }
    }

    @Test("reset(for:) forgets one kind and leaves the others alone")
    func panelResetIsPerKind() throws {
        try withDefaults { defaults in
            let store = PanelPreferences(defaults: defaults)
            store.setColumns(diskColumns(), for: .fileSystem)
            store.setColumns(archiveColumns(), for: .archive)

            store.reset(for: .archive)
            #expect(store.columns(for: .archive) == nil)
            #expect(store.columns(for: .fileSystem) == diskColumns())

            store.resetAll()
            #expect(store.columns(for: .fileSystem) == nil)
            #expect(defaults.object(forKey: store.storageKey(for: .fileSystem)) == nil)
        }
    }

    /// The stored value is meant to be auditable with `defaults read`, which means it
    /// has to be legible text carrying the upstream field names.
    @Test("The stored layout is readable JSON using the upstream field names")
    func panelStorageIsAuditableText() throws {
        try withDefaults { defaults in
            let store = PanelPreferences(defaults: defaults)
            store.setColumns([PanelColumn(property: .packedSize, width: 110, alignment: .trailing)], for: .archive)
            store.setSort(SortDescriptor(column: .name, direction: .ascending), for: .archive)

            let text = try #require(defaults.string(forKey: "FM.Columns.archive"))
            #expect(text.contains("\"Columns\""))
            #expect(text.contains("\"PropID\":\"Packed Size\""))
            #expect(text.contains("\"SortID\":\"Name\""))
            #expect(text.contains("\"SortDirection\":\"ascending\""))
        }
    }

    @Test("A corrupt or hand-mangled value reads as 'nothing stored'")
    func panelToleratesCorruptValues() throws {
        try withDefaults { defaults in
            defaults.set("{ not json", forKey: "FM.Columns.archive")
            let store = PanelPreferences(defaults: defaults)

            #expect(store.columns(for: .archive) == nil)
            #expect(store.sort(for: .archive) == nil)
        }
    }

    /// A zero-width column exists, sorts and can be dragged to, but cannot be seen —
    /// which reads as data loss rather than as a bad setting.
    @Test("A zero or duplicated column from a hand-edited value is repaired on read")
    func panelRepairsHandEditedColumns() throws {
        try withDefaults { defaults in
            let json = """
            {"Columns":[\
            {"PropID":"Name","Width":0,"Alignment":"leading"},\
            {"PropID":"Name","Width":300,"Alignment":"leading"},\
            {"PropID":"Size","Width":90,"Alignment":"sideways"}\
            ]}
            """
            defaults.set(json, forKey: "FM.Columns.fileSystem")

            let columns = try #require(PanelPreferences(defaults: defaults).columns(for: .fileSystem))
            #expect(columns.count == 2)
            #expect(columns[0].width == PanelPreferences.minimumColumnWidth)
            // An unrecognised alignment falls back to the column's natural one, so
            // numbers stay under numbers.
            #expect(columns[1].alignment == ColumnModel.defaultAlignment(for: .size))
        }
    }
}
