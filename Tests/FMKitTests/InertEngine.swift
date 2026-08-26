// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// A shared do-nothing engine for provider tests.
//
// `FolderProvider` implementations take an `any ArchiveEngine` only so they can hand
// one on when the user descends into an archive. Tests that never descend still have to
// supply one, so this answers the whole protocol with empty results: no subprocess, no
// vendored binary, nothing to clean up.

import Foundation
import ArchiveCore

struct InertEngine: ArchiveEngine {
    var identifier: String { "inert" }

    func capabilities() async throws -> EngineCapabilities {
        EngineCapabilities(versionDescription: "inert")
    }

    /// An empty listing: enough for `ArchiveFolderProvider.open` to succeed without ever
    /// reading the bytes of whatever file the test created.
    func list(_ request: ListRequest) async throws -> ArchiveListing {
        ArchiveListing(url: request.archiveURL, entries: [])
    }

    func extract(_ request: ExtractRequest) -> ArchiveOperationStream { Self.noEvents() }
    func test(_ request: TestRequest) -> ArchiveOperationStream { Self.noEvents() }
    func compress(_ request: CompressRequest) -> ArchiveOperationStream { Self.noEvents() }
    func delete(_ request: DeleteRequest) -> ArchiveOperationStream { Self.noEvents() }
    func rename(_ request: RenameRequest) -> ArchiveOperationStream { Self.noEvents() }
    func hash(_ request: HashRequest) -> ArchiveOperationStream { Self.noEvents() }
    func benchmark(_ request: BenchmarkRequest) -> ArchiveOperationStream { Self.noEvents() }

    func readEntry(_ request: ReadEntryRequest) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { $0.finish() }
    }

    private static func noEvents() -> ArchiveOperationStream {
        AsyncThrowingStream { $0.finish() }
    }
}
