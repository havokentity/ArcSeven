<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Security

ArcSeven opens files created by strangers. Every archive is untrusted input, and the
threat model below is written from that assumption.

## Reporting a vulnerability

Open a private security advisory on the repository, or contact the maintainer
directly. Please do not open a public issue for an unfixed vulnerability. Expect an
acknowledgement within a week.

## Threat model

### 1. Path traversal on extraction ("zip slip")

An archive member named `../../../../etc/cron.d/evil` must never be written outside
the destination directory. This is the highest-severity issue an archive tool can
have and it is exploited in the wild.

**Mitigation.** Every destination path is resolved with symlinks followed, then
checked to be a descendant of the extraction root *before* any bytes are written.
A member that escapes is refused and reported as a warning; extraction of the
remaining members continues. Absolute paths and drive-letter prefixes are stripped
unless the user explicitly chose "Absolute pathnames".

### 2. Symlink escape

A member may be a symlink to `/` or to a directory outside the destination, with a
later member written *through* it. Checking paths at write time is not enough,
because the link is created first.

**Mitigation.** Symlink members whose targets resolve outside the extraction root are
not created. Directory components are verified not to be symlinks before descending.
Restoring symlinks at all is a user-visible option.

### 3. Decompression bombs

A few hundred kilobytes can expand to petabytes. Nested archives multiply this.

**Mitigation.** Extraction tracks total bytes written against the sum of the members'
declared sizes and against absolute and ratio ceilings. Crossing a ceiling pauses
the operation and asks the user rather than filling the disk. Nested-archive
browsing applies its own depth limit.

### 4. Passphrase exposure in the process table

This is a real, accepted limitation of the current engine, documented rather than
hidden.

`7zz` accepts a passphrase on **stdin** for reading operations (`x`, `e`, `t`, `l`),
and ArcSeven uses that path, so passphrases for extraction never reach the process
table. It does **not** accept stdin for the creation path (`a`): the passphrase must
be on argv as `-p<password>`, where any local process running `ps` can see it for
the lifetime of the child.

**Consequence.** On a multi-user machine, another logged-in user can observe a
passphrase while an encrypted archive is being *created*. There is no way to avoid
this with the subprocess engine; it is one of the motivations for the planned
in-process XPC engine, which keeps passphrases in memory. `EngineCapabilities`
exposes this as `keepsPasswordsInProcess`, and the UI is expected to surface it.

### 5. Silent loss of encryption

If `-p` is dropped, mistyped, or ignored, `7zz` produces a **plaintext archive and
exits 0**. Handing the user an unencrypted archive they believe is protected is the
worst failure this component can have.

**Mitigation.** Every encrypting creation is followed by `verifyEncryption(of:)`,
which re-lists the archive and throws `encryptionVerificationFailed` unless the
result is genuinely encrypted. This check is not optional and must never be removed
as an optimisation.

### 6. Quarantine propagation

Files extracted from a downloaded archive inherit the download's untrusted status on
macOS. Stripping `com.apple.quarantine` would silently disable Gatekeeper for
anything shipped inside an archive.

**Mitigation.** The quarantine attribute is propagated from the source archive to
every extracted file. ArcSeven never removes it.

### 7. Untrusted archive metadata in the UI

Member paths, comments and method strings are attacker-controlled. They are rendered
as text only — never interpreted as markup, format strings, or shell input. Paths
containing control characters, right-to-left overrides, or newlines are displayed
with those characters escaped, so a member cannot disguise its extension.

### 8. Malformed archives crashing a decoder

**Mitigation.** The decoder runs in a child process. A crash is surfaced as
`terminatedBySignal` and loses one operation, not the application or the user's
other work. This process isolation is a deliberate part of choosing the subprocess
engine and is a reason to be cautious about moving decoding in-process.

### 9. Extension transport

The Quick Look and Quick Action extensions communicate with the container app over
an authenticated channel scoped to the app group. The Quick Look extension parses
headers only and never spawns `7zz`.

## Out of scope

- The cryptographic strength of 7-Zip's AES-256 implementation; ArcSeven does not
  implement cryptography.
- Physical access, and attackers already running code as the user.
- RAR is extract-only. See `NOTICE` for the unRAR restriction.
