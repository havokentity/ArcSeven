// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// The Finder → app handoff request, and the App Group it travels through.
//
// The Finder Sync extension WRITES a request and the app READS-THEN-REMOVES it, so one
// click produces one operation. A request file is created once, consumed once, deleted.
// Nothing here is a queue two readers share and nothing is updated in place.
//
// This file imports **Foundation and nothing else** — no AppKit (the appex must stay
// headless), no FinderSync (the app does not link it), and none of the project's own
// modules, which is why no `#if canImport(...)` module-guard appears below. That is not
// tidiness: it is what makes the file compilable into both targets, which is the point.
//
// ---------------------------------------------------------------------------------------
// Why a file in a shared container rather than a URL query string
// ---------------------------------------------------------------------------------------
// The obvious design is `arcseven://compress?path=/a&path=/b`. It is wrong twice over:
//
//   1. Paths are not URL-safe text. `#`, `?`, `%`, `&`, `+` and newlines are all legal in
//      an APFS filename, so every path needs percent-encoding and the decode has to be
//      byte-exact or the app opens the wrong file — or no file. Round-tripping arbitrary
//      bytes through a URL is a bug farm, not a protocol.
//   2. A URL is not a bulk transport. LaunchServices imposes its own length limits, and
//      "select 5 000 files, choose Compress" is an ordinary thing for a user to do.
//
// So the URL carries **one UUID** and nothing else, and the payload travels as JSON in the
// App Group container both sides already share. The URL is a doorbell; the file is the
// parcel.
//
// ---------------------------------------------------------------------------------------
// Replay and trust
// ---------------------------------------------------------------------------------------
// Any process can invoke `arcseven://finder-request?id=<uuid>` — a custom URL scheme is not
// an authenticated channel. What that gets an attacker is nothing, provided the app follows
// two rules, which is why the API below makes them the easy path:
//
//   * The request *file* lives in the App Group container, which only code signed by our
//     Team ID and carrying the group entitlement can write. The UUID in the URL is a
//     pointer, never a payload: ignore everything in the URL except the id.
//   * ``FinderRequestStore/consume(id:)`` claims by atomic rename and deletes, so a URL
//     replayed a second later finds nothing, and ``FinderRequest/isStale(asOf:maximumAge:)``
//     rejects anything the sweep has not caught yet.
//
// ---------------------------------------------------------------------------------------
// DUPLICATE-SOURCE WARNING
// ---------------------------------------------------------------------------------------
// `Sources/App/FinderRequest.swift` is a second copy of this contract, written in parallel
// for the app target; `project.yml` currently compiles that one into ArcSeven and this one
// into FinderSync.appex. The two agree on everything that crosses the boundary — directory
// layout, file naming, JSON keys, ISO-8601 dates, the three action raw values — so the
// handoff works today, but two copies of a wire format drift the moment one side is edited.
//
// This file is deliberately a **source-compatible superset** of that one: same
// `FinderRequestAction`, `FinderRequestError` and `FinderRequestStore` spellings, plus the
// `arcseven://` half that the other copy is missing entirely. Consolidating is therefore a
// project.yml change and a deletion, not a merge: add this path to the app target's
// `sources:` and delete `Sources/App/FinderRequest.swift`. Until then, any edit here must
// be mirrored there.

import Foundation

// MARK: - App Group

/// The App Group shared by the app, the Finder Sync extension, the Quick Look preview and
/// the Quick Actions extension.
public enum ArcSevenAppGroup {
    /// The Team ID the whole bundle is signed with.
    public static let teamIdentifier = "HAMH7N3PJR"

    /// The group name as it appears in the developer portal and in conversation.
    public static let groupName = "group.com.havokentity.ArcSeven"

    /// What actually goes in an entitlements file and into
    /// `containerURL(forSecurityApplicationGroupIdentifier:)`.
    ///
    /// **Team-prefixed, and that is not optional.** macOS App Group identifiers are
    /// `<TeamID>.<group name>` (iOS ones are not, which is where the confusion comes from).
    /// The bare `group.com.havokentity.ArcSeven` resolves to a *different* — usually
    /// nonexistent — container and returns nil rather than an error, which is the silent
    /// failure where the extension writes a request the app can never find. This is the
    /// string already in `project.yml` for all four bundles and the path
    /// `~/Library/Group Containers/HAMH7N3PJR.group.com.havokentity.ArcSeven` that
    /// docs/RELEASING.md tells users to delete on uninstall.
    public static let identifier = "\(teamIdentifier).\(groupName)"

    /// The shared container, or `nil` when this process has no App Group entitlement.
    ///
    /// Tries the prefixed form first and the bare form second rather than assuming either,
    /// so a hypothetical unprefixed build still resolves. On a correctly signed bundle the
    /// first attempt succeeds and the second is never reached.
    ///
    /// `nil` means a signing or entitlements fault, never a user fault: the system creates
    /// the container on demand, so a correctly entitled process cannot fail to get one.
    public static var containerURL: URL? {
        let manager = FileManager.default
        for candidate in [identifier, groupName] {
            if let url = manager.containerURL(forSecurityApplicationGroupIdentifier: candidate) {
                return url
            }
        }
        return nil
    }
}

// MARK: - The request

/// What the user asked for in Finder.
///
/// Deliberately three verbs and no destination. The Finder surfaces have no idea where the
/// output should go, what format to use, or whether a password is needed; those are the
/// app's job, and encoding them here would mean two places that have to agree about
/// defaults. Widening this enum is a contract change affecting both targets, not a patch.
public enum FinderRequestAction: String, Codable, Sendable, Hashable, CaseIterable {
    /// Add the selection to a new archive.
    case compress
    /// Unpack the selected archive(s), choosing a destination by inspecting the archive:
    /// loose when it holds a single root item, wrapped in a folder when it would otherwise
    /// scatter its contents over the enclosing directory.
    case extract
    /// Unpack into the enclosing folder, always — no wrapper, whatever the archive holds.
    ///
    /// Distinct from `.noPaths` extraction, which is a different idea entirely: that
    /// flattens the directory structure INSIDE the archive. This only decides whether a
    /// wrapper folder is created around it.
    case extractLoose
    /// Unpack into a folder named after the archive, always.
    case extractToSubfolder
    /// Verify the selected archive's integrity without extracting it.
    case test
    /// Browse the selection in the file manager window.
    case open
}

/// One thing the user asked for, addressed to the app.
public struct FinderRequest: Codable, Sendable, Hashable, Identifiable {
    /// Spelled `FinderRequest.Action` as well as `FinderRequestAction`, because both
    /// readings are natural and a second name costs nothing next to a second definition.
    public typealias Action = FinderRequestAction

    /// Identifies the request, names its file on disk, and is what the `arcseven://` URL
    /// carries so the app can go straight to it instead of scanning.
    public var id: UUID

    /// The verb.
    public var action: FinderRequestAction

    /// The selection as absolute POSIX paths, in the order Finder presented them.
    ///
    /// Paths rather than `URL`s because this crosses a process boundary as JSON, and a URL
    /// encodes to a string with a scheme and percent-escapes — a lossy game nobody needs to
    /// play with file system paths. Paths rather than security-scoped bookmarks because the
    /// app is **not** sandboxed and opens them directly; see the security-scope note in
    /// `FinderSyncExtension.swift`.
    ///
    /// Stored byte-for-byte as Finder handed them over, with **no Unicode normalisation**.
    /// docs/DIVERGENCES.md D-23 folds names to NFC before *comparing* them; this is
    /// *resolution*, where the string goes back to the filesystem, and folding it here could
    /// produce a path that no longer opens.
    public var paths: [String]

    /// When the extension wrote it. Drives ``isStale(asOf:maximumAge:)``.
    ///
    /// - Note: The ISO-8601 encoding stores whole seconds, so a request that has been
    ///   through the container is **not** `==` to the one that was written: its `createdAt`
    ///   is truncated. Nothing here wants sub-second precision — staleness is measured in
    ///   hours — but a test that asserts round-trip equality on the whole value will fail on
    ///   that field alone, which is worth knowing before debugging it.
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        action: FinderRequestAction,
        paths: [String],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.action = action
        self.paths = paths
        self.createdAt = createdAt
    }

    /// Convenience for the writing side, which is holding URLs already.
    ///
    /// `standardizedFileURL` only rewrites the string — it removes `.`, resolves `..` and
    /// drops a trailing slash — and touches no filesystem, which is what makes it legal on
    /// Finder's menu-action path. Symlinks are deliberately not resolved: if the user
    /// selected a symlink, the app should see the symlink.
    public init(
        id: UUID = UUID(),
        action: FinderRequestAction,
        urls: [URL],
        createdAt: Date = Date()
    ) {
        self.init(
            id: id,
            action: action,
            paths: urls.map { $0.standardizedFileURL.path(percentEncoded: false) },
            createdAt: createdAt
        )
    }

    /// The selection as file URLs.
    public var urls: [URL] { paths.map { URL(fileURLWithPath: $0) } }

    /// The doorbell: `arcseven://finder-request?id=<uuid>`.
    public var launchURL: URL? { ArcSevenURLScheme.finderRequestURL(for: id) }

    /// `true` once the request is too far from now to act on.
    ///
    /// An hour is generous for "the user clicked a menu item and the app is launching", and
    /// tight enough that a replay almost never finds a live request. A request written while
    /// the app was quit, whose wake-up never arrived, describes a selection the user has
    /// long since moved on from — acting on it an hour later is a surprise, not a service.
    ///
    /// The window is symmetric — `abs`, not a one-sided comparison — so a request dated an
    /// hour in the *future* is rejected too. A few seconds of skew is ordinary clock
    /// granularity; an hour means either the clock jumped or the timestamp was fabricated to
    /// keep a stale request permanently fresh, and neither is worth acting on.
    public func isStale(
        asOf now: Date = Date(),
        maximumAge: TimeInterval = FinderRequestStore.defaultMaximumAge
    ) -> Bool {
        abs(now.timeIntervalSince(createdAt)) > maximumAge
    }
}

// MARK: - The URL scheme

/// The `arcseven://` custom scheme, spelled once.
///
/// - Important: The app must declare this scheme in `CFBundleURLTypes` (it does, via
///   `project.yml`) **and** handle it in `application(_:open:)`, which as of this writing it
///   does not — see the integration note at the end of `FinderSyncExtension.swift`. Without
///   the handler the extension writes a perfectly good request, the app launches, and
///   nothing happens.
public enum ArcSevenURLScheme {
    public static let scheme = "arcseven"

    /// The host component marking a Finder handoff, leaving room for other verbs later.
    public static let finderRequestHost = "finder-request"

    /// The only query item. Anything else in the URL must be ignored.
    public static let requestIDQueryItem = "id"

    /// Build the launch URL for a request id.
    public static func finderRequestURL(for id: UUID) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = finderRequestHost
        components.queryItems = [URLQueryItem(name: requestIDQueryItem, value: id.uuidString)]
        return components.url
    }

    /// Pull the request id out of an incoming URL, or `nil` if this is not one of ours.
    ///
    /// Case-insensitive in the scheme, the host and the UUID, because LaunchServices is free
    /// to hand a URL back lower-cased and `UUID(uuidString:)` accepts either case. Note that
    /// the *only* thing extracted is a `UUID`: everything the caller then does is driven by
    /// the file in the container, not by the URL.
    public static func requestID(from url: URL) -> UUID? {
        guard url.scheme?.lowercased() == scheme,
              url.host()?.lowercased() == finderRequestHost,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = components.queryItems?
                  .first(where: { $0.name == requestIDQueryItem })?.value
        else { return nil }
        return UUID(uuidString: value)
    }
}

// MARK: - Failures

/// Why a request could not be written, found, or read back.
///
/// Every case names the thing that went wrong precisely enough to act on. The app group case
/// in particular must never be reported as "extraction failed": the fix is a provisioning
/// one and the user's archive is fine.
public enum FinderRequestError: Error, LocalizedError, Hashable, Sendable {
    /// No App Group container. The entitlement is missing from the running binary's
    /// signature, or the container has not been provisioned for this user yet.
    case appGroupUnavailable(identifier: String)

    /// Nothing on disk under that id. Ordinary rather than alarming: it is what a second
    /// consumer sees after the first took the request, and what a replayed URL sees.
    case notFound(id: UUID)

    /// The file exists but could not be read.
    case unreadable(id: UUID, reason: String)

    /// The file was read but is not a usable request: truncated by a crash mid-write,
    /// written by an older build, or carrying an id that is not the one requested.
    case malformed(id: UUID, reason: String)

    /// The request could not be handed over.
    case writeFailed(id: UUID, reason: String)

    public var errorDescription: String? {
        switch self {
        case .appGroupUnavailable(let identifier):
            "The shared container '\(identifier)' is not available to this build of ArcSeven."
        case .notFound(let id):
            "The Finder request \(id.uuidString) is no longer available."
        case let .unreadable(id, reason):
            "The Finder request \(id.uuidString) could not be read: \(reason)"
        case let .malformed(id, reason):
            "The Finder request \(id.uuidString) is not readable by this version: \(reason)"
        case let .writeFailed(id, reason):
            "The Finder request \(id.uuidString) could not be handed to ArcSeven: \(reason)"
        }
    }
}

// MARK: - The store

/// Reads and writes request files in the shared container.
///
/// Layout, and it is deliberately boring:
///
/// ```text
/// ~/Library/Group Containers/HAMH7N3PJR.group.com.havokentity.ArcSeven/
///     Requests/
///         3A1F….json          a request waiting to be consumed
///         3A1F….claimed       a request some reader has taken, mid-decode
/// ```
///
/// One file per request means the filesystem does the locking. `rename(2)` is atomic, so the
/// reader that wins the move owns the request and every other reader gets
/// ``FinderRequestError/notFound(id:)`` — exactly-once without a lock file, a database or a
/// daemon.
///
/// A namespace of static functions rather than an instance type: it owns no state, and under
/// Swift 6 strict concurrency a stored `FileManager` would make every holder non-`Sendable`
/// for no benefit.
public enum FinderRequestStore {
    // MARK: Identity

    /// The app group, unprefixed. Forwards to ``ArcSevenAppGroup``, which is where these
    /// live; they are re-exported here because that is where call sites reach for them.
    public static let appGroupIdentifier = ArcSevenAppGroup.groupName

    /// The Team ID macOS requires in front of it.
    public static let teamIdentifierPrefix = ArcSevenAppGroup.teamIdentifier

    /// What is passed to `FileManager`, and what appears in all four bundles' entitlements.
    public static let containerIdentifier = ArcSevenAppGroup.identifier

    /// Subdirectory of the container holding requests. Its own directory so the container
    /// stays legible when staging and caches move in next to it.
    public static let requestsDirectoryName = "Requests"

    /// Extension of a request waiting to be consumed.
    public static let requestFileExtension = "json"

    /// Extension of a request a reader has taken but not yet decoded. Left behind only by a
    /// crash between the rename and the delete, and swept by ``pruneStale(olderThan:)``.
    public static let claimedFileExtension = "claimed"

    /// Requests older than this are junk. Enforced on both sides: swept from disk by the
    /// writer, and rejected by ``FinderRequest/isStale(asOf:maximumAge:)`` by the reader.
    public static let defaultMaximumAge: TimeInterval = 3600

    // MARK: Locations

    /// The `Requests` directory, or nil when there is no shared container.
    ///
    /// Resolves a location; it creates nothing and does not care whether the directory
    /// exists. ``write(_:)`` creates it, and every reader treats "absent" and "empty" as the
    /// same answer.
    public static func requestsDirectory() -> URL? {
        ArcSevenAppGroup.containerURL?
            .appending(path: requestsDirectoryName, directoryHint: .isDirectory)
    }

    /// The file a request id lives in.
    ///
    /// Always built from a parsed `UUID`, never from raw URL text — that is what makes
    /// `?id=../../../../etc/passwd` a non-event. `uuidString` is 36 characters of hex and
    /// hyphens and can express nothing else.
    private static func fileURL(for id: UUID, in directory: URL) -> URL {
        directory.appending(path: "\(id.uuidString).\(requestFileExtension)", directoryHint: .notDirectory)
    }

    private static func claimURL(for id: UUID, in directory: URL) -> URL {
        directory.appending(path: "\(id.uuidString).\(claimedFileExtension)", directoryHint: .notDirectory)
    }

    // MARK: Writing — the extension's half

    /// Hand a request to the app. Returns where it landed.
    ///
    /// Written with `.atomic`, so a reader woken by the URL can never see a half-written
    /// file: the data goes to a sibling temp file and is renamed into place.
    @discardableResult
    public static func write(_ request: FinderRequest) throws -> URL {
        guard let directory = requestsDirectory() else {
            throw FinderRequestError.appGroupUnavailable(identifier: containerIdentifier)
        }
        let url = fileURL(for: request.id, in: directory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try makeEncoder().encode(request).write(to: url, options: [.atomic])
        } catch {
            throw FinderRequestError.writeFailed(id: request.id, reason: error.localizedDescription)
        }
        return url
    }

    // MARK: Reading — the app's half

    /// Read a request without consuming it.
    ///
    /// Pair with ``remove(id:)`` once the work has actually started, or use
    /// ``consume(id:)`` when more than one route can reach the same request.
    public static func read(id: UUID) throws -> FinderRequest {
        guard let directory = requestsDirectory() else {
            throw FinderRequestError.appGroupUnavailable(identifier: containerIdentifier)
        }
        let url = fileURL(for: id, in: directory)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw FinderRequestError.notFound(id: id)
        }
        return try decodeRequest(at: url, id: id)
    }

    /// Take a request: exactly one caller succeeds, and the file is gone afterwards.
    ///
    /// The rename is the claim. A second caller — a start-up sweep racing the `arcseven://`
    /// URL that named the same id — finds nothing to move and gets
    /// ``FinderRequestError/notFound(id:)``, which is the correct answer rather than an error
    /// worth showing anyone.
    ///
    /// A request that cannot be decoded is deleted rather than left behind: it cannot be
    /// acted on by this build or any later one, and leaving it means re-reading it on every
    /// launch forever.
    @discardableResult
    public static func consume(id: UUID) throws -> FinderRequest {
        guard let directory = requestsDirectory() else {
            throw FinderRequestError.appGroupUnavailable(identifier: containerIdentifier)
        }
        let manager = FileManager.default
        let claim = claimURL(for: id, in: directory)
        try? manager.removeItem(at: claim)
        do {
            try manager.moveItem(at: fileURL(for: id, in: directory), to: claim)
        } catch {
            // Never existed, or someone else won the rename. Same outcome either way.
            throw FinderRequestError.notFound(id: id)
        }
        defer { try? manager.removeItem(at: claim) }
        return try decodeRequest(at: claim, id: id)
    }

    /// Forget a request, consumed or not.
    ///
    /// Best effort by design: the app must not fail an extraction because the note that asked
    /// for it could not be torn up.
    public static func remove(id: UUID) {
        guard let directory = requestsDirectory() else { return }
        let manager = FileManager.default
        try? manager.removeItem(at: fileURL(for: id, in: directory))
        try? manager.removeItem(at: claimURL(for: id, in: directory))
    }

    /// Ids of the requests waiting to be consumed, oldest first.
    ///
    /// This is how the app picks up work handed over while it was not running. The ordering
    /// matters: a user who fired three verbs at Finder in a row expects them in that order.
    public static func pendingRequestIDs() -> [UUID] {
        guard let directory = requestsDirectory() else { return [] }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []
        return contents
            .filter { $0.pathExtension == requestFileExtension }
            .compactMap { url -> (id: UUID, date: Date)? in
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
                    return nil
                }
                return (id, modificationDate(of: url) ?? .distantPast)
            }
            .sorted { $0.date < $1.date }
            .map(\.id)
    }

    // MARK: Housekeeping

    /// Delete anything in the directory older than `seconds`.
    ///
    /// Opportunistic: the extension calls this every time it writes. Nothing else ever
    /// cleans the directory up, and a request whose app launch failed — ArcSeven was moved
    /// or deleted, the user cancelled a Gatekeeper prompt — is never consumed. Without this
    /// the container accumulates one small file per abandoned click, forever.
    ///
    /// Sweeps by file modification date rather than by the encoded `createdAt`, and does NOT
    /// skip hidden files, so abandoned `.claimed` files and the dot-prefixed temp files an
    /// interrupted atomic write leaves behind are collected too. A request too corrupt to
    /// decode still has an mtime.
    ///
    /// Deliberately silent, and it swallows every error: housekeeping must never be the
    /// reason a user's click does nothing.
    public static func pruneStale(olderThan seconds: TimeInterval = defaultMaximumAge) {
        guard let directory = requestsDirectory() else { return }
        let manager = FileManager.default
        let cutoff = Date(timeIntervalSinceNow: -seconds)
        let contents = (try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsSubdirectoryDescendants]
        )) ?? []
        for url in contents where (modificationDate(of: url) ?? .distantPast) < cutoff {
            try? manager.removeItem(at: url)
        }
    }

    // MARK: Plumbing

    private static func decodeRequest(at url: URL, id: UUID) throws -> FinderRequest {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw FinderRequestError.unreadable(id: id, reason: error.localizedDescription)
        }
        let request: FinderRequest
        do {
            request = try makeDecoder().decode(FinderRequest.self, from: data)
        } catch {
            throw FinderRequestError.malformed(id: id, reason: error.localizedDescription)
        }
        // The id is in the filename *and* in the payload. Disagreement means the file was
        // not written by us or was corrupted; either way it is not the request that was
        // asked for, and acting on someone else's paths is the one mistake worth refusing.
        guard request.id == id else {
            throw FinderRequestError.malformed(
                id: id,
                reason: "the file carries identifier \(request.id.uuidString)"
            )
        }
        return request
    }

    private static func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// Fresh each call. `JSONEncoder` is not `Sendable`, and a shared one reachable from both
    /// an appex and the app is exactly the kind of static this project does not keep
    /// (project.yml house rule 4).
    ///
    /// ISO-8601 dates on purpose: `Date`'s default strategy is a bare `Double` since 2001,
    /// and `cat`-ing one of these files while debugging a Finder menu that "does nothing" is
    /// the whole diagnostic. Both sides must agree, so both sides get them from here.
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
