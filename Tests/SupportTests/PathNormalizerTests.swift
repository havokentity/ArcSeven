// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// Filename spelling: the NFC/NFD trap, the ':'/'/' swap, Windows portability, and the
// reduction of hostile entry names to something that can only land inside a folder.

import Foundation
import Testing
@testable import Support

@Suite("PathNormalizer")
struct PathNormalizerTests {
    /// `café` with a precomposed U+00E9 - what a Windows-made archive carries.
    private let precomposed = "caf\u{00E9}.txt"
    /// `café` as `e` + U+0301 - what readdir hands back on HFS+.
    private let decomposed = "cafe\u{0301}.txt"

    // MARK: - Unicode form

    @Test("The two spellings of café are different bytes and the same file")
    func normalisationTrap() {
        // If this ever fails the test is wrong, not the code: the premise of the whole
        // file is that these are not equal as strings-of-bytes.
        #expect(Array(precomposed.utf8) != Array(decomposed.utf8))
        #expect(PathNormalizer.namesMatch(precomposed, decomposed))
        #expect(PathNormalizer.comparisonForm(decomposed) == precomposed)
        #expect(PathNormalizer.comparisonForm(precomposed) == precomposed)
    }

    @Test("Comparison folds normalisation but never case")
    func comparisonDoesNotFoldCase() {
        #expect(!PathNormalizer.namesMatch("README.md", "readme.md"))
    }

    @Test("Decomposition is available for callers that need the other direction")
    func decomposition() {
        #expect(PathNormalizer.decomposedForm(precomposed) == decomposed)
    }

    // MARK: - The ':' / '/' swap

    @Test("A POSIX colon is what the Finder shows as a slash, and back")
    func colonSlashSwap() {
        #expect(PathNormalizer.displayName(forDiskName: "2026:04:01 notes") == "2026/04/01 notes")
        #expect(PathNormalizer.diskName(forDisplayName: "2026/04/01 notes") == "2026:04:01 notes")
    }

    // MARK: - Portability

    @Test("Ordinary names are portable", arguments: [
        "readme.txt", "a b c.tar.gz", "café.txt", "日本語.txt", "console.txt", "CONCERT",
        "..secret", "a..b", "_", "COM10", "LPT0",
    ])
    func portableNames(name: String) {
        #expect(PathNormalizer.isPortableComponent(name))
    }

    @Test("Windows-illegal names are not portable", arguments: [
        "a<b", "a>b", "a:b", "a\"b", #"a\b"#, "a|b", "a?b", "a*b", "a\u{0007}b",
        "trailing.", "trailing ", "", ".", "..",
    ])
    func unportableNames(name: String) {
        #expect(!PathNormalizer.isPortableComponent(name))
    }

    /// Windows matches the device name on the stem before the first dot, in any case, in
    /// every directory. `con.txt` cannot be created on Windows at all.
    @Test("Reserved device names are not portable in any spelling", arguments: [
        "CON", "con", "Con", "CON.txt", "con.tar.gz", "PRN", "AUX", "NUL",
        "COM1", "com9", "LPT1", "lpt9",
    ])
    func reservedDeviceNames(name: String) {
        #expect(PathNormalizer.isReservedDeviceName(name))
        #expect(!PathNormalizer.isPortableComponent(name))
    }

    @Test("Names that only look like device names are portable", arguments: [
        "CONSOLE", "COM", "COM0.txt", "PRNT", "NULL", "LPT", "MYCON",
    ])
    func nearMissDeviceNames(name: String) {
        #expect(!PathNormalizer.isReservedDeviceName(name))
        #expect(PathNormalizer.isPortableComponent(name))
    }

    @Test("A whole path is portable only when every component is")
    func portablePaths() {
        #expect(PathNormalizer.isPortableName("docs/api/index.html"))
        #expect(!PathNormalizer.isPortableName("docs/CON/index.html"))
        #expect(!PathNormalizer.isPortableName("docs/a?b/index.html"))
        #expect(!PathNormalizer.isPortableName(""))
    }

    @Test("A 255-byte name passes and a longer one does not")
    func lengthCeiling() {
        #expect(PathNormalizer.isPortableComponent(String(repeating: "a", count: 255)))
        #expect(!PathNormalizer.isPortableComponent(String(repeating: "a", count: 256)))
        // Multi-byte scalars bust the POSIX byte ceiling long before the UTF-16 one.
        #expect(!PathNormalizer.isPortableComponent(String(repeating: "é", count: 200)))
    }

    // MARK: - Archive spelling

    @Test("Escaping produces a name Windows will accept", arguments: [
        "a<b", "a>b", "a:b", "a\"b", "a|b", "a?b", "a*b", "trailing.", "trailing ",
        "CON", "con.txt", "COM1.log", "a\u{0007}b",
    ])
    func escapingProducesPortableNames(name: String) {
        let escaped = PathNormalizer.portableComponent(name)
        #expect(PathNormalizer.isPortableComponent(escaped))
    }

    @Test("Escaping round-trips exactly", arguments: [
        "a<b", "a>b", "a:b", "a\"b", "a|b", "a?b", "a*b", "trailing.", "trailing ",
        "a.. ", "a . ", "CON", "con.txt", "COM1.log", "readme.txt", "café.txt",
        "a\u{0007}b", "a\u{001F}b",
    ])
    func escapingRoundTrips(name: String) {
        let escaped = PathNormalizer.portableComponent(name)
        #expect(PathNormalizer.diskComponent(escaped) == name)
    }

    /// A name that has already been escaped must survive a second pass unchanged,
    /// otherwise a path that crosses the portability boundary twice - into a nested
    /// archive, say - accumulates escapes.
    @Test("Escaping is idempotent", arguments: ["a:b", "CON", "trailing.", "a?b"])
    func escapingIsIdempotent(name: String) {
        let once = PathNormalizer.portableComponent(name)
        #expect(PathNormalizer.portableComponent(once) == once)
    }

    @Test("A portable name is left alone")
    func portableNamesAreUntouched() {
        #expect(PathNormalizer.portableComponent("readme.txt") == "readme.txt")
        #expect(PathNormalizer.normalizeForArchive("docs/api/index.html") == "docs/api/index.html")
    }

    @Test("Archive spelling composes to NFC so the name renders elsewhere")
    func archiveSpellingComposes() {
        #expect(PathNormalizer.portableComponent(decomposed) == precomposed)
    }

    @Test("Separators survive, component by component")
    func archiveSpellingIsPerComponent() {
        let normalised = PathNormalizer.normalizeForArchive("a:b/CON/plain.txt")
        #expect(normalised.split(separator: "/").count == 3)
        #expect(PathNormalizer.normalizeForDisk(normalised) == "a:b/CON/plain.txt")
    }

    /// `.` and `..` are path syntax. Escaping them would turn a traversal into a real
    /// file with an invisible name, which is a worse outcome than leaving PathSafety to
    /// refuse it.
    @Test("Dot components are left for the safety gate to refuse")
    func dotComponentsAreNotEscaped() {
        #expect(PathNormalizer.normalizeForArchive("../a") == "../a")
        #expect(PathNormalizer.normalizeForArchive("./a") == "./a")
    }

    // MARK: - Disk spelling

    /// The one decode that does not return the input scalar: a component cannot hold a
    /// slash at the POSIX layer, and `:` is exactly how macOS spells the user's slash.
    @Test("An escaped slash becomes a colon on disk, where the Finder shows it as a slash")
    func escapedSlashBecomesColon() {
        let escapedSlash = "a\u{F02F}b"
        #expect(PathNormalizer.diskComponent(escapedSlash) == "a:b")
        #expect(PathNormalizer.displayName(forDiskName: "a:b") == "a/b")
    }

    @Test("The device marker decodes to nothing")
    func deviceMarkerIsRemoved() {
        #expect(PathNormalizer.diskComponent("CON\u{F000}") == "CON")
        #expect(PathNormalizer.diskComponent("CON\u{F000}.txt") == "CON.txt")
    }

    /// Extraction must write the archive's own characters (D-23). Re-normalising here
    /// would silently rename files on their way out.
    @Test("Disk spelling does not touch Unicode form")
    func diskSpellingPreservesUnicodeForm() {
        #expect(PathNormalizer.normalizeForDisk(decomposed) == decomposed)
        #expect(PathNormalizer.normalizeForDisk(precomposed) == precomposed)
    }

    // MARK: - Untrusted entry names

    @Test("Traversal is removed rather than resolved", arguments: [
        ("../../etc/passwd", "etc/passwd"),
        ("a/../../b", "a/b"),
        ("/etc/passwd", "etc/passwd"),
        (#"C:\Windows\System32\x"#, "Windows/System32/x"),
        ("C:secret.txt", "secret.txt"),
        (#"..\..\evil"#, "evil"),
        ("./a//b/./c", "a/b/c"),
        ("docs/api/index.html", "docs/api/index.html"),
    ])
    func sanitisation(entryPath: String, expected: String) {
        #expect(PathNormalizer.sanitizeForExtraction(entryPath) == expected)
    }

    @Test("Nothing survivable means an empty string, which the caller must treat as a refusal", arguments: [
        "", "..", "../..", "/", ".", "C:", "C:/",
    ])
    func sanitisationCanRefuse(entryPath: String) {
        #expect(PathNormalizer.sanitizeForExtraction(entryPath).isEmpty)
    }

    /// The property that matters: whatever goes in, what comes out is relative, has no
    /// `..`, and therefore cannot address anything above the folder it is joined to.
    @Test("A sanitised path is always relative and traversal-free", arguments: [
        "../../etc/passwd", "/etc/passwd", #"C:\Windows\x"#, "a/../../b", "....//..//x",
        #"\\server\share\x"#, "//../..", "a/./../..",
    ])
    func sanitisationInvariant(entryPath: String) {
        let sanitised = PathNormalizer.sanitizeForExtraction(entryPath)
        #expect(!sanitised.hasPrefix("/"))
        #expect(!sanitised.split(separator: "/").contains(".."))
        #expect(!sanitised.contains("\\"))
    }
}
