// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte

import Testing
@testable import ArchiveCore

@Suite("ArchiveEntry attributes")
struct ArchiveEntryAttributesTests {
    /// `7zz` prints `A_` and `D_` — the underscore marks an entry whose attribute word
    /// also carries POSIX bits — for every member of an archive made on a Mac or on
    /// Linux. The parser accepted only `RHSDA`, so those tokens matched nothing and the
    /// Archive and Directory flags were dropped for exactly the archives this app writes.
    @Test("Unix-flavoured attribute tokens keep their DOS flags")
    func unixFlavouredTokens() {
        let file = ArchiveEntry.Attributes.parse("A_ -rw-r--r--")
        #expect(file.dos.contains(.archive))
        #expect(file.posixMode == 0o644)
        #expect(file.posixFileType == "-")
        #expect(!file.isDirectory)

        let directory = ArchiveEntry.Attributes.parse("D_ drwxr-xr-x")
        #expect(directory.dos.contains(.directory))
        #expect(directory.posixMode == 0o755)
        #expect(directory.isDirectory)
    }

    @Test("Windows-only tokens still parse")
    func windowsTokens() {
        let hidden = ArchiveEntry.Attributes.parse("HA")
        #expect(hidden.dos.contains(.hidden))
        #expect(hidden.dos.contains(.archive))
        #expect(hidden.posixMode == nil)

        let directory = ArchiveEntry.Attributes.parse("D")
        #expect(directory.isDirectory)
    }

    /// A token that is not made of attribute letters is left alone rather than
    /// half-read: `raw` keeps it for the inspector and no flag is invented from it.
    @Test("An unrecognised token sets no flags")
    func unrecognisedToken() {
        let odd = ArchiveEntry.Attributes.parse("Q?")
        #expect(odd.dos.isEmpty)
        #expect(odd.posixMode == nil)
        #expect(odd.raw == "Q?")
    }
}
