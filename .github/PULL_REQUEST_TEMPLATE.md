<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
## What this changes

<!-- One or two sentences. Link the issue if there is one. -->

## Checklist

- [ ] Commits are signed off (`git commit -s`) — the DCO is required, see [CONTRIBUTING.md](../CONTRIBUTING.md)
- [ ] `swift build` and `swift test` pass
- [ ] New first-party files carry the `// SPDX-License-Identifier: GPL-3.0-or-later` header
- [ ] **No 7-Zip, unRAR, p7zip or NanaZip source has been copied into this repo.**
      Describing upstream behaviour and citing `file:line` is expected; pasting code is not.
- [ ] Any deliberate behavioural difference from Windows 7zFM is recorded in [docs/DIVERGENCES.md](../docs/DIVERGENCES.md)
- [ ] Parser changes come with byte-level fixtures that do not require a real `7zz`

## Fidelity note

<!-- If this touches a surface that 7zFM also has, say whether the result is 1:1,
     adapted, or deliberately different — and why. -->
