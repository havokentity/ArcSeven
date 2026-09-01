// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte
//
// The real Security.framework calls, against a real keychain.
//
// `SecItem*` is the sort of API where a wrong attribute dictionary fails silently in a
// direction that looks like success — `SecItemAdd` over an existing item returns
// `errSecDuplicateItem` rather than replacing it, so an add-first implementation keeps
// the OLD passphrase when the user changes it, and nothing in the type system notices.
// A fake store cannot catch any of that, which is why this suite talks to the keychain.
//
// It uses its own `kSecAttrService`, so it can neither read nor delete the items the app
// itself stores, and every test cleans up after itself. The suite skips when the keychain
// is unavailable — a locked or absent login keychain on a CI runner — so a bare checkout
// still passes.

import Foundation
import Security
import Testing
@testable import FMKit

/// The service used by this suite only. Never `KeychainArchivePasswordStore.defaultService`:
/// a test must not be able to delete a passphrase the user asked ArcSeven to remember.
let keychainTestService = "com.havokentity.ArcSeven.Tests.ArchivePassword"

/// Whether this process can actually add, read and delete a keychain item.
///
/// Probed rather than assumed: an unsigned test binary on a runner with no unlocked login
/// keychain gets `errSecInteractionNotAllowed`, and a suite that fails there would be
/// reporting on the runner rather than on the code.
func keychainIsUsable() -> Bool {
    let probe = URL(fileURLWithPath: "/tmp/arcseven-keychain-probe-\(UUID().uuidString).7z")
    let store = KeychainArchivePasswordStore(service: keychainTestService)
    defer { store.removePassword(forArchiveAt: probe) }
    guard store.save("probe", forArchiveAt: probe) else { return false }
    return store.password(forArchiveAt: probe) == "probe"
}

@Suite("Keychain archive password store", .enabled(if: keychainIsUsable()))
struct KeychainArchivePasswordStoreTests {
    private let store = KeychainArchivePasswordStore(service: keychainTestService)

    /// A path that no other test in this run will use, so the parallel runner cannot
    /// have two tests fighting over one keychain item.
    private func scratchArchive() -> URL {
        URL(fileURLWithPath: "/tmp/arcseven-\(UUID().uuidString)/secret.7z")
    }

    @Test("A saved passphrase comes back")
    func roundTrip() {
        let archive = scratchArchive()
        defer { store.removePassword(forArchiveAt: archive) }

        #expect(store.password(forArchiveAt: archive) == nil, "nothing stored yet")
        #expect(store.save("correct horse battery staple", forArchiveAt: archive))
        #expect(store.password(forArchiveAt: archive) == "correct horse battery staple")
    }

    /// The `SecItemAdd`-versus-`SecItemUpdate` trap. Adding over an existing item fails
    /// with `errSecDuplicateItem` and leaves the old value in place, so a user who
    /// changed the archive's passphrase would keep being handed the old one.
    @Test("Saving again replaces the passphrase rather than keeping the old one")
    func saveReplaces() {
        let archive = scratchArchive()
        defer { store.removePassword(forArchiveAt: archive) }

        #expect(store.save("first", forArchiveAt: archive))
        #expect(store.save("second", forArchiveAt: archive))
        #expect(store.password(forArchiveAt: archive) == "second")
    }

    @Test("Removing forgets it, and removing again is silent")
    func removeIsIdempotent() {
        let archive = scratchArchive()
        #expect(store.save("x", forArchiveAt: archive))

        store.removePassword(forArchiveAt: archive)
        #expect(store.password(forArchiveAt: archive) == nil)
        // Eviction runs whenever a remembered passphrase fails, including when there was
        // none, so a second delete must not be an error.
        store.removePassword(forArchiveAt: archive)
        #expect(store.password(forArchiveAt: archive) == nil)
    }

    @Test("Each archive gets its own item")
    func itemsAreKeyedPerArchive() {
        let first = scratchArchive()
        let second = scratchArchive()
        defer {
            store.removePassword(forArchiveAt: first)
            store.removePassword(forArchiveAt: second)
        }

        #expect(store.save("one", forArchiveAt: first))
        #expect(store.save("two", forArchiveAt: second))
        #expect(store.password(forArchiveAt: first) == "one")
        #expect(store.password(forArchiveAt: second) == "two")

        store.removePassword(forArchiveAt: first)
        #expect(store.password(forArchiveAt: second) == "two", "the wrong item was deleted")
    }

    /// `/tmp` is a symlink to `/private/tmp`, so the same archive reached by two spellings
    /// must be one item — otherwise the user is prompted for an archive they just asked to
    /// be remembered.
    @Test("The same archive under two spellings is one item")
    func pathsAreStandardized() {
        let directory = "/tmp/arcseven-\(UUID().uuidString)"
        let plain = URL(fileURLWithPath: "\(directory)/secret.7z")
        let winding = URL(fileURLWithPath: "\(directory)/./secret.7z")
        defer { store.removePassword(forArchiveAt: plain) }

        #expect(KeychainArchivePasswordStore.account(for: plain)
                    == KeychainArchivePasswordStore.account(for: winding))
        #expect(store.save("shared", forArchiveAt: plain))
        #expect(store.password(forArchiveAt: winding) == "shared")
    }

    /// Passphrases are not ASCII, and `Data(password.utf8)` has to survive the round trip
    /// byte for byte — including the leading and trailing spaces `PasswordPromptResult`
    /// deliberately never trims.
    @Test("Non-ASCII and space-padded passphrases survive intact")
    func exoticPassphrasesRoundTrip() {
        for passphrase in [" leading", "trailing ", "παρώδη", "🔐🔐", "a\tb\nc"] {
            let archive = scratchArchive()
            defer { store.removePassword(forArchiveAt: archive) }
            #expect(store.save(passphrase, forArchiveAt: archive))
            #expect(store.password(forArchiveAt: archive) == passphrase, "\(passphrase)")
        }
    }

    /// The store must not be able to see the app's own items, or a test run could delete
    /// what the user asked to have remembered.
    @Test("The test service is isolated from the app's")
    func serviceIsIsolated() {
        #expect(keychainTestService != KeychainArchivePasswordStore.defaultService)

        let archive = scratchArchive()
        defer { store.removePassword(forArchiveAt: archive) }
        #expect(store.save("isolated", forArchiveAt: archive))

        let appStore = KeychainArchivePasswordStore()
        #expect(appStore.password(forArchiveAt: archive) == nil)
    }
}
