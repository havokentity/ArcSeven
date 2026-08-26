// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// Entry point.
//
// Explicit rather than `@main`: the delegate must exist before `run()` so that an
// `open` event delivered at launch (double-clicking a .7z in Finder) is not dropped,
// and the activation policy has to be set before the first window appears.

import AppKit
#if canImport(SettingsUI)   // module-guard
import SettingsUI
#endif

// Before anything can read a setting.
//
// `SettingsStore.init` registers the same table, but that initialiser does not run until the
// user first opens the settings window — so on a fresh install every key was simply absent
// from the standard domain, and `bool(forKey: "Options.CascadedMenu")` answered `false` for a
// setting that ships ticked. Registration has to happen at the process entry point, ahead of
// the delegate, because `application(_:open:)` can fire before `applicationDidFinishLaunching`
// and reads a setting on the way through.
SettingsStore.registerDefaults()

let application = NSApplication.shared
let controller = AppDelegate()
application.delegate = controller
application.setActivationPolicy(.regular)
application.run()
