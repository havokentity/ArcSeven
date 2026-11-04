// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte

import Foundation
import Testing
@testable import ArchiveCore

@Suite("Delete guard")
struct DeleteGuardTests {
    /// `7zz d archive` with no member names deletes EVERY member. The engine must refuse
    /// the request before anything is spawned — which this proves by pointing it at an
    /// executable that does not exist: a spawn would fail with `launchFailed`, not with
    /// `invalidRequest`.
    @Test("An empty delete is refused before the child is spawned")
    func emptyDeleteIsRefused() async {
        let engine = SevenZipCLIEngine(executableURL: URL(fileURLWithPath: "/nonexistent/7zz"))
        let request = DeleteRequest(
            archiveURL: URL(fileURLWithPath: "/nonexistent/archive.7z"),
            entryPaths: []
        )

        var started = false
        do {
            for try await event in engine.delete(request) {
                if case .started(.delete) = event { started = true }
            }
            Issue.record("an empty delete must throw")
        } catch let error as ArchiveError {
            guard case .invalidRequest = error else {
                Issue.record("expected invalidRequest, got \(error)")
                return
            }
        } catch {
            Issue.record("expected an ArchiveError, got \(error)")
        }
        #expect(started, "the stream still opens with its .started event")
    }
}
