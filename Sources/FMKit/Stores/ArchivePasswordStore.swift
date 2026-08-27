// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// "Remember in Keychain", implemented.
//
// The Password prompt has always carried the checkbox, and `PasswordPromptResult` has
// always carried the flag, and through 0.1.5 nothing anywhere read it: a grep for
// `Keychain` outside `PasswordDialogController.swift` found nothing at all. The
// checkbox's tooltip promised the archive would open without asking again, and the user
// was re-prompted every single time. A security-adjacent control that lies is worse
// than one that is absent, so either this file exists or the checkbox does not.
//
// ## Why generic passwords, keyed on the path
//
// A `kSecClassGenericPassword` item with a fixed service and the archive's path as its
// account is the shape the login keychain is built for: one item per archive, visible
// and deletable in Keychain Access, protected by the login keychain's own unlock state,
// and never written to iCloud (`kSecAttrSynchronizable` is left off, so the item is
// local to this Mac).
//
// Keying on the path has one consequence worth stating plainly: MOVING OR RENAMING AN
// ARCHIVE ORPHANS ITS ITEM. The user is prompted again, and the old item lingers until
// they delete it in Keychain Access. The alternative — keying on the archive's contents
// — would mean hashing a file that may be gigabytes before a prompt can be shown, and
// would break the moment a single member changed. 7-Zip does not remember passwords at
// all, so there is no upstream behaviour to match; Finder-adjacent apps key on the path.
//
// ## What is deliberately NOT here
//
// No "forget everything" sweep, and no eviction when an archive is deleted. Both need a
// list of what is stored, which means `kSecMatchLimitAll` over the service and a
// Settings pane to show it. Until that exists, Keychain Access is the management UI,
// which is a defensible answer precisely because the items are ordinary and legible
// there.

import Foundation
import Security

/// Remembers archive passphrases between launches.
///
/// A protocol, not a bare type, so the window's open path can be tested without touching
/// the tester's real login keychain.
public protocol ArchivePasswordStore: Sendable {
    /// The remembered passphrase for `url`, or `nil` when there is none.
    func password(forArchiveAt url: URL) -> String?

    /// Remember `password` for `url`, replacing any passphrase already stored.
    ///
    /// - Returns: `false` when the keychain refused. Callers treat that as "not
    ///   remembered" rather than as an error worth interrupting the user for: the
    ///   archive is already open by the time this is called.
    @discardableResult
    func save(_ password: String, forArchiveAt url: URL) -> Bool

    /// Forget the passphrase for `url`. Silent when there was none.
    func removePassword(forArchiveAt url: URL)
}

/// The real thing: one generic-password item per archive in the login keychain.
public struct KeychainArchivePasswordStore: ArchivePasswordStore {
    /// The `kSecAttrService` every item shares, which is what makes them findable and
    /// recognisable in Keychain Access.
    public static let defaultService = "com.havokentity.ArcSeven.ArchivePassword"

    private let service: String

    /// - Parameter service: Overridden only by tests, which use their own service so a
    ///   test run cannot collide with — or delete — the user's real items.
    public init(service: String = Self.defaultService) {
        self.service = service
    }

    /// The account attribute: the archive's standardized path.
    ///
    /// Standardized so that `/tmp/a.7z` and `/private/tmp/./a.7z` are one item rather
    /// than two, which would otherwise leave the user prompted for an archive they had
    /// just asked to be remembered.
    static func account(for url: URL) -> String { url.standardizedFileURL.path }

    private func baseQuery(for url: URL) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account(for: url),
        ]
    }

    public func password(forArchiveAt url: URL) -> String? {
        var query = baseQuery(for: url)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        // A non-UTF-8 item is not a passphrase this app wrote. Answering `nil` puts the
        // user back in front of the prompt, which is recoverable; forcing a decode is not.
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public func save(_ password: String, forArchiveAt url: URL) -> Bool {
        let data = Data(password.utf8)
        let query = baseQuery(for: url)

        // Update first, add second. `SecItemAdd` over an existing item fails with
        // `errSecDuplicateItem` rather than replacing it, so an add-then-update order
        // would silently keep the OLD passphrase after the user changed it.
        let updated = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }

        var insertion = query
        insertion[kSecValueData as String] = data
        // Available whenever the keychain is unlocked, and only on this Mac. NOT
        // `...AfterFirstUnlock`, which exists for background work; opening an archive is
        // something a present user does.
        insertion[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        // What Keychain Access shows in its list, so the item can be recognised and
        // deleted by hand.
        insertion[kSecAttrLabel as String] = "ArcSeven: \(url.lastPathComponent)"
        insertion[kSecAttrDescription as String] = "Archive passphrase"
        return SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess
    }

    public func removePassword(forArchiveAt url: URL) {
        // `errSecItemNotFound` is the expected answer half the time — eviction runs
        // whenever a remembered passphrase fails, including when there was none.
        _ = SecItemDelete(baseQuery(for: url) as CFDictionary)
    }
}
