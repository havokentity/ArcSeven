// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte

import Foundation
import Testing
@testable import Support

/// `Quarantine` was correct, tested by nobody, and called by nobody — so `docs/SECURITY.md`
/// §6 promised Gatekeeper propagation that never happened. These tests pin the behaviour
/// itself; the call site is pinned by `FMUITests`.
@Suite("Quarantine propagation")
struct QuarantinePropagationTests {
    private let attribute = "com.apple.quarantine"
    private let sample = "0083;00000000;ArcSevenTests;"

    private func withScratch<T>(_ body: (URL) throws -> T) throws -> T {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("arcseven-qtn-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try body(dir)
    }

    private func setxattr(_ value: String, on url: URL) {
        let bytes = Array(value.utf8)
        _ = url.withUnsafeFileSystemRepresentation { path in
            Darwin.setxattr(path, attribute, bytes, bytes.count, 0, 0)
        }
    }

    private func getxattr(_ url: URL) -> String? {
        url.withUnsafeFileSystemRepresentation { path -> String? in
            let size = Darwin.getxattr(path, attribute, nil, 0, 0, 0)
            guard size > 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: size)
            guard Darwin.getxattr(path, attribute, &buffer, size, 0, 0) == size else { return nil }
            return String(bytes: buffer, encoding: .utf8)
        }
    }

    @Test("A quarantined archive marks every extracted file")
    func propagatesToWholeTree() throws {
        try withScratch { dir in
            let archive = dir.appendingPathComponent("download.zip")
            try Data("z".utf8).write(to: archive)
            setxattr(sample, on: archive)

            let output = dir.appendingPathComponent("out/nested", isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let payload = output.appendingPathComponent("app.sh")
            try Data("#!/bin/sh".utf8).write(to: payload)

            let marked = try Quarantine.propagate(
                from: archive, toTreeAt: dir.appendingPathComponent("out")
            )

            #expect(marked >= 2, "root and nested payload should both be marked")
            #expect(getxattr(payload) == sample, "the extracted file must inherit quarantine")
        }
    }

    @Test("An unquarantined archive marks nothing")
    func doesNotInventQuarantine() throws {
        try withScratch { dir in
            let archive = dir.appendingPathComponent("local.zip")
            try Data("z".utf8).write(to: archive)   // no xattr: made locally, trusted

            let output = dir.appendingPathComponent("out", isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let payload = output.appendingPathComponent("file.txt")
            try Data("hello".utf8).write(to: payload)

            let marked = try Quarantine.propagate(from: archive, toTreeAt: output)

            #expect(marked == 0)
            #expect(getxattr(payload) == nil, "must not quarantine files from a trusted archive")
        }
    }

    @Test("Propagation never removes an existing quarantine")
    func neverStrips() throws {
        try withScratch { dir in
            let archive = dir.appendingPathComponent("plain.zip")
            try Data("z".utf8).write(to: archive)

            let output = dir.appendingPathComponent("out", isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let payload = output.appendingPathComponent("already.txt")
            try Data("x".utf8).write(to: payload)
            setxattr(sample, on: payload)

            _ = try Quarantine.propagate(from: archive, toTreeAt: output)

            #expect(getxattr(payload) == sample, "an existing quarantine must survive")
        }
    }
}
