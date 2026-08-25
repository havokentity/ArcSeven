// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// Filename reality on macOS, which is not the reality any archive format assumes.
//
// Four facts drive everything below, and every one of them corrupts data when ignored:
//
//   1. Unicode form. HFS+ *stores* a decomposed (NFD-ish) name whatever you hand it, and
//      APFS stores what you give it but compares normalisation-insensitively. Archives
//      written on Windows carry precomposed (NFC) names. "café" is therefore two
//      different byte strings depending on which side produced it, and a byte comparison
//      says they are different files. That is how an overwrite check concludes "no
//      collision" for a name the filesystem considers already taken - silent data loss.
//      See docs/DIVERGENCES.md D-23.
//
//   2. ':' and '/' are swapped between the POSIX layer and the Finder layer. Classic Mac
//      OS used ':' as the path separator and allowed '/' inside a name; macOS inverted
//      that for POSIX, and kept compatibility by translating. A file created as
//      `touch 'a:b'` shows in Finder as `a/b`; a file the user names `a/b` in Finder is
//      `a:b` to open(2). Still true today. Archives contain either, because both layers
//      have written archives for twenty years.
//
//   3. Characters Windows forbids - `< > : " / \ | ? *` and everything below U+0020 - are
//      perfectly legal in an APFS name, as are trailing dots and spaces. Writing such a
//      name into an archive produces a file the recipient cannot extract, or that
//      Windows silently renames.
//
//   4. Windows reserves device names - CON, PRN, AUX, NUL, COM1-9, LPT1-9 - in *every*
//      directory, matched on the stem before the first dot and case-insensitively. A file
//      called `con.txt` cannot be created on Windows at all.
//
// The escaping used here for (3) and (4) is not invented: it is the mapping macOS's own
// SMB client uses when it writes a Mac name onto a Windows share - the offending scalar
// is moved into the U+F000 private-use page by adding 0xF000 to it. Windows accepts those
// scalars in a filename, macOS translates them back when it reads the share, and the
// transform is exactly reversible. Choosing the same table means a name that survives a
// round trip through a Windows file share also survives a round trip through an ArcSeven
// portable archive, and agrees with itself at both ends.

import Foundation

/// Name and path transforms between the on-disk POSIX world and the archive world.
///
/// Nothing here decides *whether* a path is safe to write - that is ``PathSafety``, which
/// is the only authority on containment. This type is about spelling.
public enum PathNormalizer {
    // MARK: - Unicode form

    /// The form names are compared, sorted, matched and collision-checked in: NFC.
    ///
    /// Applied to both sides of every comparison between an on-disk name and an archive
    /// entry name. It is deliberately *not* applied to anything that gets written: entry
    /// names go into archives as received and extracted files are created with the
    /// archive's own bytes, so passing an archive through ArcSeven never re-normalises
    /// anybody's filenames (D-23).
    public static func comparisonForm(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
    }

    /// Whether two names refer to the same file as far as the filesystem is concerned.
    ///
    /// - Note: Case is *not* folded. APFS is case-insensitive by default and HFS+ was
    ///   too, but both can be formatted case-sensitive, and an archive is case-sensitive
    ///   always. Callers that know they are talking to a case-insensitive volume fold the
    ///   case themselves; guessing here would break the case-sensitive volumes.
    public static func namesMatch(_ lhs: String, _ rhs: String) -> Bool {
        comparisonForm(lhs) == comparisonForm(rhs)
    }

    /// Canonical decomposed form.
    ///
    /// - Important: This is plain NFD, which is *not* what HFS+ stores. HFS+ applies a
    ///   frozen variant that leaves U+2000-U+2FFF, U+F900-U+FAFF and U+2F800-U+2FA1F
    ///   composed (Apple QA1173), because the ranges were carved out when the format was
    ///   defined and could never be revised without invalidating every existing volume.
    ///   Nothing in ArcSeven needs to reproduce that variant - we never have to predict
    ///   the bytes HFS+ will store, only compare what it hands back, and ``comparisonForm``
    ///   composes both sides so the difference cannot matter.
    public static func decomposedForm(_ name: String) -> String {
        name.decomposedStringWithCanonicalMapping
    }

    // MARK: - The ':' / '/' swap

    /// The name as the Finder shows it, given the name open(2) sees.
    ///
    /// A POSIX `:` is displayed as `/`. This is presentation only - never feed the result
    /// to a file API.
    public static func displayName(forDiskName name: String) -> String {
        name.replacingOccurrences(of: ":", with: "/")
    }

    /// The name open(2) needs, given the name the user typed or the Finder showed.
    ///
    /// A displayed `/` inside a single component becomes a POSIX `:`. Callers must have
    /// split the path on its real separators first, otherwise this eats them.
    public static func diskName(forDisplayName name: String) -> String {
        name.replacingOccurrences(of: "/", with: ":")
    }

    // MARK: - Portability

    /// Whether every component of `path` can be created verbatim on Windows, and so on
    /// any platform anyone is likely to hand the archive to.
    ///
    /// Splits on `/` and judges each component, so it answers for a single name and for a
    /// whole entry path alike. `.` and `..` are reported unportable: they are path
    /// syntax, never filenames.
    public static func isPortableName(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return false }
        return components.allSatisfy { isPortableComponent(String($0)) }
    }

    /// The single-component form of ``isPortableName(_:)``.
    public static func isPortableComponent(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != ".." else { return false }

        // NTFS counts UTF-16 units; POSIX counts bytes. Both ceilings are 255 and a name
        // that clears one can still bust the other, so both are checked.
        guard name.utf16.count <= 255, name.utf8.count <= 255 else { return false }

        if name.unicodeScalars.contains(where: needsEscaping) { return false }
        if let last = name.last, last == "." || last == " " { return false }
        if isReservedDeviceName(name) { return false }

        // A name already carrying private-use escapes *is* portable - Windows creates
        // those files quite happily - and saying so is what makes
        // `isPortableComponent(portableComponent(x))` true for every x, and
        // `portableComponent` idempotent. Escaping an escaped name is therefore a no-op
        // rather than a corruption, which matters because a name can pass through the
        // portability path more than once on its way into a nested archive.
        return true
    }

    /// Whether the stem before the first dot is one of Windows' per-directory device
    /// names. `CON`, `con.txt` and `CoN.tar.gz` are all reserved; `console.txt` is not.
    ///
    /// - Note: Recent Windows also reserves the superscript spellings `COM¹ COM² COM³`
    ///   and `LPT¹ LPT² LPT³`. They are omitted deliberately: escaping them would rename
    ///   files for a rule that only the newest Windows enforces, and the failure mode of
    ///   *not* escaping them is a rejected create on that one platform, not data loss.
    public static func isReservedDeviceName(_ name: String) -> Bool {
        let stem = name.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return reservedDeviceNames.contains(stem.uppercased())
    }

    // MARK: - Disk name to archive name

    /// The portable spelling of an on-disk path, for an archive meant to leave macOS.
    ///
    /// - Composes to NFC, because a decomposed name renders as `cafe´` in a good half of
    ///   the Windows and Linux tools that will open the archive.
    /// - Moves Windows-illegal scalars, trailing dots and trailing spaces into the U+F000
    ///   private-use page, exactly as macOS's SMB client does.
    /// - Marks a reserved device name so Windows will accept it.
    ///
    /// ``normalizeForDisk(_:)`` reverses all three.
    ///
    /// - Important: This is the *portable* spelling, applied when the user has asked for
    ///   an archive their Windows and Linux recipients can open. It is not applied to
    ///   names copied from another archive, which go in exactly as received (D-23), and
    ///   it is not applied when the user has not asked for it: a plain macOS-to-macOS
    ///   archive stores the POSIX bytes unchanged, because those bytes are correct.
    public static func normalizeForArchive(_ path: String) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components
            .map { component -> String in
                // `.` and `..` are separator syntax; escaping them would turn a traversal
                // into a real file named U+F02E, which is worse than leaving it for
                // PathSafety to reject.
                let text = String(component)
                if text == "." || text == ".." { return text }
                return portableComponent(text)
            }
            .joined(separator: "/")
    }

    /// The portable spelling of one path component.
    public static func portableComponent(_ name: String) -> String {
        guard !name.isEmpty else { return name }

        var escaped = String.UnicodeScalarView()
        for scalar in name.precomposedStringWithCanonicalMapping.unicodeScalars {
            if needsEscaping(scalar), let moved = Unicode.Scalar(privateUseBase + scalar.value) {
                escaped.append(moved)
            } else {
                escaped.append(scalar)
            }
        }

        // Windows strips trailing dots and spaces silently, so `report.` and `report`
        // become the same file and one of them is gone. Escaping the *final* scalar is
        // enough to stop it: once `a. ` ends in U+F020 the dot before it is no longer
        // trailing and survives untouched, so `a.. ` round-trips exactly. The loop is
        // written as a loop anyway because it terminates on the escaped scalar itself,
        // which is easier to read than an off-by-one argument in a comment.
        var result = String(escaped)
        while let last = result.unicodeScalars.last, last == "." || last == " " {
            result.unicodeScalars.removeLast()
            if let moved = Unicode.Scalar(privateUseBase + last.value) {
                result.unicodeScalars.append(moved)
            }
        }

        // NUL cannot occur in a POSIX name, so its escape slot - U+F000 exactly - is
        // permanently free. It is reused as the device-name marker, which keeps the whole
        // scheme reversible with one table and no second sentinel.
        if isReservedDeviceName(result), let marker = Unicode.Scalar(privateUseBase) {
            let stemLength = result.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
                .first?.count ?? result.count
            let insertion = result.index(result.startIndex, offsetBy: stemLength)
            result.unicodeScalars.insert(marker, at: insertion)
        }

        return result
    }

    // MARK: - Archive name to disk name

    /// The on-disk POSIX spelling of an archive entry path.
    ///
    /// Reverses ``normalizeForArchive(_:)``: private-use escapes are decoded and the
    /// device marker is dropped. Two deliberate asymmetries:
    ///
    /// - A decoded `/` becomes `:`, not `/`. A component cannot contain a slash at the
    ///   POSIX layer at all, and `:` is precisely how macOS spells "the user's slash" -
    ///   the Finder will show the original name back. This is the only decode that does
    ///   not return the exact input scalar, and it is the correct one.
    /// - Unicode form is left alone. The file must be created with the archive's own
    ///   characters (D-23); HFS+ will decompose it on the way in without being asked, and
    ///   APFS keeps what it is given. Forcing either form here would mean the extracted
    ///   name differs from the name in the archive, which is exactly what D-23 forbids.
    public static func normalizeForDisk(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map { diskComponent(String($0)) }
            .joined(separator: "/")
    }

    /// The on-disk spelling of one component. See ``normalizeForDisk(_:)``.
    public static func diskComponent(_ name: String) -> String {
        var decoded = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            guard privateUseRange.contains(scalar.value) else {
                decoded.append(scalar)
                continue
            }
            // U+F000 is the device marker and decodes to nothing.
            guard scalar.value != privateUseBase else { continue }
            guard let original = Unicode.Scalar(scalar.value - privateUseBase) else { continue }
            decoded.append(original == "/" ? ":" : original)
        }
        return String(decoded)
    }

    // MARK: - Display

    /// Make an attacker-controlled name safe to *show*, without changing what it means.
    ///
    /// A member name is chosen by whoever built the archive, and the user decides whether
    /// to extract or open it largely by reading its extension. Two families of scalar let
    /// a name lie about that:
    ///
    /// * **Bidi overrides.** `invoice\u{202E}gnp.exe` renders as `invoice exe.png`. The
    ///   name really does end in `.exe`; the display is reversed after the override. This
    ///   is the classic RLO spoof and it is used in the wild.
    /// * **Control characters.** A newline or carriage return splits a name across lines
    ///   or lets the tail overwrite the head in a single-line field.
    ///
    /// Both are replaced with a visible `\u{XXXX}` escape.
    ///
    /// Only the explicit bidi *control* scalars are escaped, never ordinary right-to-left
    /// letters: a genuinely Arabic or Hebrew filename must keep rendering as itself. The
    /// distinction is the whole point — escaping RTL script would break real names while
    /// doing nothing about the attack, which does not need RTL letters at all.
    ///
    /// - Note: For display only. Never feed the result back to the engine as a member
    ///   name; it no longer identifies the same entry.
    public static func displaySafe(_ name: String) -> String {
        guard name.unicodeScalars.contains(where: needsDisplayEscaping) else { return name }
        var out = ""
        out.reserveCapacity(name.unicodeScalars.count)
        for scalar in name.unicodeScalars {
            if needsDisplayEscaping(scalar) {
                out += String(format: "\\u{%04X}", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Scalars that can make a name render as something other than what it is.
    private static func needsDisplayEscaping(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F:          // C0 and DEL
            return true
        case 0x80...0x9F:                // C1
            return true
        case 0x200E, 0x200F:             // LEFT/RIGHT-TO-LEFT MARK
            return true
        case 0x202A...0x202E:            // embeddings and overrides, incl. RLO
            return true
        case 0x2066...0x2069:            // isolates
            return true
        default:
            return false
        }
    }

    // MARK: - Untrusted entry paths

    /// Reduce an attacker-controlled archive entry path to a *relative* POSIX path that
    /// cannot leave the directory it is appended to.
    ///
    /// Drive letters, UNC prefixes, leading separators, `.` and `..` are removed;
    /// backslashes are read as separators; NUL scalars are dropped. The result is never
    /// absolute and never contains `..`, so joining it to a root always lands inside that
    /// root - but "inside the root" is not the same as "safe to write", because an
    /// existing symlink in the way still escapes. ``PathSafety/resolvedDestination(root:entryPath:)``
    /// is the gate that must be passed before any byte is written; this function only
    /// produces the candidate.
    ///
    /// - Returns: A relative path, or `""` when nothing survives. An empty result must be
    ///   treated as a refusal, never as "the root itself".
    public static func sanitizeForExtraction(_ entryPath: String) -> String {
        // Backslash is read as a separator. The ZIP appnote mandates `/`, but archives
        // written by older Windows tools carry `\`, and 7-Zip's own extractor translates
        // it. Reading it as a separator can only split a name into more components, which
        // makes the checks below stricter, never weaker - the fail-closed direction.
        let unified = entryPath.replacingOccurrences(of: "\\", with: "/")

        var components: [String] = []
        for rawComponent in unified.split(separator: "/", omittingEmptySubsequences: true) {
            var component = String(rawComponent)

            // `C:` from `C:\Windows\x`, and the drive-relative `C:file` form, which is
            // not the same thing and is easy to forget.
            if components.isEmpty, let stripped = strippingDriveLetter(component) {
                component = stripped
            }

            component = String(String.UnicodeScalarView(component.unicodeScalars.filter { $0.value != 0 }))

            if component.isEmpty || component == "." { continue }
            // Dropped, not resolved. Resolving `a/../../b` yields `../b`, which escapes;
            // dropping yields `a/b`, which is merely in the wrong place. The gate refuses
            // the path outright - this function exists to be safe, not to be clever.
            if component == ".." { continue }

            components.append(component)
        }

        return components.joined(separator: "/")
    }

    // MARK: - Private

    /// `C:` and `C:file` alike; returns the remainder, or nil when there is no drive.
    private static func strippingDriveLetter(_ component: String) -> String? {
        var scalars = Substring(component)
        guard let first = scalars.first, first.isLetter, first.isASCII else { return nil }
        scalars = scalars.dropFirst()
        guard scalars.first == ":" else { return nil }
        return String(scalars.dropFirst())
    }

    /// Scalars Windows refuses in a filename and macOS accepts without comment.
    private static func needsEscaping(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.value < 0x20 { return true }
        return windowsIllegalScalars.contains(scalar)
    }

    private static let windowsIllegalScalars: Set<Unicode.Scalar> = ["<", ">", ":", "\"", "/", "\\", "|", "?", "*"]

    private static let privateUseBase: UInt32 = 0xF000
    private static let privateUseRange: Range<UInt32> = 0xF000 ..< 0xF100

    private static let reservedDeviceNames: Set<String> = {
        var names: Set<String> = ["CON", "PRN", "AUX", "NUL"]
        for index in 1 ... 9 {
            names.insert("COM\(index)")
            names.insert("LPT\(index)")
        }
        return names
    }()
}
