// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// Entry point.
//
// Explicit rather than `@main`: the delegate must exist before `run()` so that an
// `open` event delivered at launch (double-clicking a .7z in Finder) is not dropped,
// and the activation policy has to be set before the first window appears.

import AppKit

let application = NSApplication.shared
let controller = AppDelegate()
application.delegate = controller
application.setActivationPolicy(.regular)
application.run()
