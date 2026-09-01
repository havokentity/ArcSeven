// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte

import Testing
import ArchiveCore
@testable import FMKit

@Suite("FolderItem")
struct FolderItemTests {
    @Test("An archive entry becomes a navigable row only when it is a directory")
    func directoryIsNavigable() {
        let file = ArchiveEntry(path: "docs/readme.txt", isDirectory: false)
        let dir = ArchiveEntry(path: "docs", isDirectory: true)
        #expect(FolderItem(entry: file).isNavigable == false)
        #expect(FolderItem(entry: dir).isNavigable == true)
    }
}
