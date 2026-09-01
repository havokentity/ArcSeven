// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte
//
// The one place where raw engine bytes become Swift text.
//
// `7zz` prints filenames as the bytes it was given. On macOS those are very nearly
// always UTF-8, but "very nearly" is not "always": an archive can store a member name
// in any encoding at all, and the name is reproduced on stdout unchanged. Malformed
// bytes are therefore a normal input here, not an exceptional one.
//
// Nothing downstream can act on a decode failure. A listing with one mis-encoded
// member name is still a listing; an `ERROR:` line with one mis-encoded path is still
// the diagnostic the user needs. Refusing to decode would throw all of that away to
// protect against nothing, so the decode is lossy by design: every malformed sequence
// becomes `U+FFFD` and the rest of the line survives intact.

/// Turns engine output bytes into text.
enum EngineText {
    /// UTF-8 text for engine bytes, substituting `U+FFFD` for anything malformed.
    ///
    /// Never fails and never drops a line. See the file header for why the failable
    /// initializer is the wrong trade at this boundary.
    static func decode(_ bytes: some Collection<UInt8>) -> String {
        // `optional_data_string_conversion` prefers `String(bytes:encoding:)`, whose
        // nil return is exactly what this boundary cannot use. Disabled once, here, so
        // the decision lives in one reviewable place instead of at every call site.
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: bytes, as: UTF8.self)
    }
}
