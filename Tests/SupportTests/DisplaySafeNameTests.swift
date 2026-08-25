// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte

import Foundation
import Testing
@testable import Support

/// `docs/SECURITY.md` §7 claimed member names were displayed with control characters and
/// bidi overrides escaped "so a member cannot disguise its extension". Nothing escaped
/// anything — the panel rendered `item.name` verbatim. These pin the real behaviour.
@Suite("Display-safe names")
struct DisplaySafeNameTests {
    /// The attack: everything after the override renders reversed, so the name appears to
    /// end in `.png` while actually ending in `.exe`.
    @Test("A right-to-left override is escaped")
    func rloIsEscaped() {
        let spoofed = "invoice\u{202E}gnp.exe"
        let safe = PathNormalizer.displaySafe(spoofed)
        let rlo = Unicode.Scalar(0x202E) ?? " "
        #expect(!safe.unicodeScalars.contains(rlo))
        #expect(safe.contains("\\u{202E}"))
        #expect(safe.hasSuffix(".exe"), "the real extension must still be legible")
    }

    @Test("Every bidi control scalar is escaped")
    func allBidiControlsEscaped() {
        let values = [
            0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
            0x2066, 0x2067, 0x2068, 0x2069,
        ]
        for value in values {
            guard let scalar = Unicode.Scalar(UInt32(value)) else {
                Issue.record("U+\(String(value, radix: 16)) is not a valid scalar")
                continue
            }
            let safe = PathNormalizer.displaySafe("a\(Character(scalar))b")
            #expect(!safe.unicodeScalars.contains(scalar), "U+\(String(value, radix: 16)) survived")
        }
    }

    @Test("Newlines and control characters are escaped")
    func controlCharactersEscaped() {
        let safe = PathNormalizer.displaySafe("first\nsecond\rthird\u{7F}")
        #expect(!safe.contains("\n"))
        #expect(!safe.contains("\r"))
        #expect(safe.contains("\\u{000A}"))
        #expect(safe.contains("\\u{007F}"))
    }

    /// The distinction that makes this usable: the attack needs bidi CONTROL scalars, not
    /// right-to-left letters. Escaping Arabic or Hebrew text would mangle real filenames
    /// and stop nothing.
    @Test("Ordinary non-ASCII names are left completely alone")
    func legitimateNamesUntouched() {
        for name in ["café_日本.txt", "مرحبا.txt", "שלום.txt", "emoji-🗜.7z", "plain.txt"] {
            #expect(PathNormalizer.displaySafe(name) == name, "\(name) was altered")
        }
    }

    @Test("A clean name is returned without allocating a new string")
    func cleanNamesShortCircuit() {
        let name = "perfectly-ordinary-name.txt"
        #expect(PathNormalizer.displaySafe(name) == name)
    }
}
