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

**Mitigation.** Containment is **7-Zip's**, not ArcSeven's. `7zz` strips leading
separators, drive-letter prefixes and `..` components from member paths, so a
traversal member lands flattened inside the destination instead of escaping it.
`Tests/ArchiveCoreTests/ExtractionContainmentTests.swift` builds hostile ZIPs at the
byte level — `7zz` will not create such a member itself — and asserts that nothing is
written outside the destination, including under the `-spf`/`-spf2` path modes.

**What ArcSeven does not do.** It does not inspect member paths before extraction.
`PathSafety` exists and is correct, but is used only by the overwrite pre-scan; it is
not on the extraction path. Through 0.1.2 this section claimed ArcSeven resolved and
checked every destination itself, refusing escapees with a warning. It never did. The
protection was real and the description of it was not, which is the more dangerous of
the two failures: it invites a reviewer to conclude the work is already done.

Treat the vendored `7zz` version as load-bearing. The containment tests are what
catches a regression if it is bumped or replaced.

### 2. Symlink escape

A member may be a symlink to `/` or to a directory outside the destination, with a
later member written *through* it. Checking paths at write time is not enough,
because the link is created first.

**Mitigation.** Again 7-Zip's. `7zz` **does** create the symlink member — it is not
refused — but it will not write a later member through it: the write fails with
`errno=20 : Not a directory` and is reported as a sub-item error. Verified against
26.02 with a hand-built archive pairing a `/`-relative link with a member addressed
through it.

**What ArcSeven does not do.** It does not examine link targets, and does not check
directory components for symlinks before descending. Through 0.1.2 this section
claimed both. `ExtractRequest.restoreSymbolicLinks` is likewise inert: nothing reads
it, no switch implements it — `-snl` is compression-only and makes no difference on
extraction — and no dialog exposes it. It is always effectively `true`.

### 3. Decompression bombs

A few hundred kilobytes can expand to petabytes. Nested archives multiply this.

**Mitigation, partial.** Before extraction runs, `ExpansionPolicy` totals the uncompressed
size the archive declares for the members being extracted and compares it against three
ceilings: an absolute one (64 GiB), an expansion ratio (300×, ignored below a 1 GiB result
so that a tiny file of zeros does not cry wolf), and the free space on the destination
volume. Crossing any of them asks the user, showing the figures, and offers to proceed.

**It asks rather than refuses**, deliberately. Sparse disk images, logs of one repeated
line and tarballs of zeros all reach absurd ratios honestly, and blocking them would be
wrong.

**What this does not do.** The figures come from the archive's own header, which is
attacker-controlled. An archive that understates every member's size passes the check and
then writes whatever it likes: there is no live byte accounting and no mid-write kill. So
this catches the bomb built by the standard recipe — whose headers are honest, because the
compressor wrote them — and does not catch one built specifically to defeat it.

A real guarantee needs the extraction to be metered as it runs and the child killed when it
overruns, which the subprocess engine cannot do without polling the destination. That is
worth building and is not built.

Through 0.1.5 this section described byte tracking, ceilings and a prompt as though they
existed. None of it did; extraction ran to completion or to a full disk.

**A correction, because this section has now been wrong twice.** The paragraph above
replaced a false claim in 0.1.5 and introduced another: it credited `ListRequest` with an
output-byte cap. `ListRequest` has no cap of any kind — it holds an archive URL, a format
override, a password and a time zone. The cap lives on `ReadEntryRequest.maximumByteCount`
and bounds a single-member read, not a listing. Listing a hostile archive is unbounded.

### 4. Passphrase exposure in the process table

Verified empirically against the vendored 7-Zip 26.02 binary. The behaviour is not
what the switch documentation implies, and the details matter:

- A **bare `-p`** does *not* mean "read the password from stdin". It means an
  **empty** password, and it suppresses the prompt. Using it against an encrypted
  archive fails with "Cannot open encrypted archive. Wrong password?".
- Omitting **both `-y` and `-p`** makes `7zz` print `Enter password:` and read the
  answer from **stdin**. A pipe is sufficient; no controlling terminal is required
  (confirmed with the child in its own session via `setsid`). **This is the path
  ArcSeven uses for every read operation** — list, test, extract, and single-entry
  streaming. The passphrase never reaches argv, so it is never visible in `ps`.
- The **creation** path has no such prompt. `7zz a` with no `-p` does **not** ask:
  it writes an **unencrypted** archive and exits **0**. The passphrase must be
  passed as `-p<password>` on argv, where any local process can observe it for the
  lifetime of the child.

**Residual exposure.** On a multi-user machine, another logged-in user can observe a
passphrase while an encrypted archive is being **created**. Reading an encrypted
archive is not affected. There is no way to close this gap with the subprocess
engine, and it is one of the motivations for the planned in-process XPC engine.
`EngineCapabilities.keepsPasswordsInProcess` reports `false` for the CLI engine and
the UI is expected to surface it.

**Consequence for `-y`.** Because the prompt only appears when `-y` is absent, read
operations carrying a password omit `-y`. Every such invocation therefore passes an
explicit overwrite mode (`-ao*`) so that no *other* prompt can block the child. See
`SevenZipCLIEngine.PasswordDelivery`.

### 5. Silent loss of encryption

If `-p` is dropped, mistyped, or ignored, `7zz` produces a **plaintext archive and
exits 0**. Handing the user an unencrypted archive they believe is protected is the
worst failure this component can have.

**Mitigation.** Every encrypting creation is followed by `verifyEncryption(of:)`,
which re-lists the archive and throws `encryptionVerificationFailed` unless the
result is genuinely encrypted. This check is not optional and must never be removed
as an optimisation.

This is not theoretical. Piping a passphrase to `7zz a` on stdin — the obvious thing
to try, and what the read paths do — produces an **unencrypted archive with exit
code 0**, silently. The guard caught exactly that during development
(`LiveEngineTests.encryptedRoundTrip`).

### 6. Quarantine propagation

Files extracted from a downloaded archive inherit the download's untrusted status on
macOS. Stripping `com.apple.quarantine` would silently disable Gatekeeper for
anything shipped inside an archive.

**Mitigation.** The quarantine attribute is propagated from the source archive to
every extracted file. ArcSeven never removes it.

### 7. Untrusted archive metadata in the UI

Member paths, comments and method strings are attacker-controlled. They are rendered
as text only — never interpreted as markup, format strings, or shell input.

**Mitigation.** `PathNormalizer.displaySafe` replaces C0/C1 control characters and the
bidi control scalars (`U+200E`, `U+200F`, `U+202A`–`U+202E`, `U+2066`–`U+2069`) with
visible `\u{XXXX}` escapes. Without it, `invoice\u{202E}gnp.exe` renders as
`invoice exe.png`: the name really does end in `.exe`, and everything after the
override is drawn reversed. That is the RLO spoof, and it is used in the wild.

Only the explicit bidi *control* scalars are escaped, never ordinary right-to-left
letters — an Arabic or Hebrew filename must keep rendering as itself. Escaping RTL
script would break real names and stop nothing, since the attack needs no RTL letters.

**Applied at:** the file panel's Name column, and the Properties inspector's title and
item heading. Window titles built from the archive's own filename on disk are not
escaped; that name comes from the file system, not from archive contents.

Through 0.1.2 this section asserted the escaping already happened. It did not — the
panel rendered `item.name` verbatim.

### 8. Malformed archives crashing a decoder

**Mitigation.** The decoder runs in a child process. A crash is surfaced as
`terminatedBySignal` and loses one operation, not the application or the user's
other work. This process isolation is a deliberate part of choosing the subprocess
engine and is a reason to be cautious about moving decoding in-process.

### 9. Extension transport

The Finder extension does not talk to the app over XPC. It writes a request file into
the shared app-group container
(`~/Library/Group Containers/HAMH7N3PJR.group.com.havokentity.ArcSeven`) and the app
consumes it. "Authenticated" only in the sense that the container is gated by an
entitlement: writing there requires the app-group entitlement, which requires a
signature from this team. Filenames must parse as UUIDs and stale requests are pruned.

The trust boundary is therefore *same-team code*, not the user's whole machine. An
attacker who can already ship code signed by this team is out of scope, as is one
already running as the user.

The Quick Look extension parses container headers itself and never runs `7zz` —
verified by construction: the helper lives in the app's bundle, and an appex may not
spawn it. `SevenZipSignatureReader` exists precisely so the appex does not need to.

## Out of scope

- The cryptographic strength of 7-Zip's AES-256 implementation; ArcSeven does not
  implement cryptography.
- Physical access, and attackers already running code as the user.
- RAR is extract-only. See `NOTICE` for the unRAR restriction.
