// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// The menu bar, built in code rather than from a nib.
//
// Keys follow the Finder preset described in docs/SHORTCUTS.md: Mac-native by
// default, with 7zFM's Windows bindings available later as the "7-Zip Classic"
// preset. So Cmd+Up is "enclosing folder" (7zFM's Backspace), Cmd+Down opens the
// selection (7zFM's Enter), and Cmd+I shows properties (7zFM's Alt+Enter).

import AppKit

@MainActor
enum MainMenuBuilder {
    static func install() {
        let main = NSMenu()
        main.addItem(applicationMenuItem())
        main.addItem(fileMenuItem())
        main.addItem(editMenuItem())
        main.addItem(viewMenuItem())
        main.addItem(goMenuItem())
        main.addItem(windowMenuItem())
        NSApp.mainMenu = main
    }

    // MARK: Menus

    private static func applicationMenuItem() -> NSMenuItem {
        let name = "ArcSeven"
        let menu = NSMenu(title: name)
        menu.addItem(withTitle: "About \(name)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())

        // Targeted at the shared updater rather than left to the responder chain: it is
        // not in the chain, so a nil target would leave the item permanently greyed out.
        // Through 0.1.3 this item did not exist at all — Sparkle.framework shipped in
        // every build, fully configured and signed, and nothing ever asked it anything.
        let updates = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(UpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updates.target = UpdaterController.shared
        menu.addItem(updates)
        menu.addItem(.separator())

        menu.addItem(withTitle: "Settings…", action: Selector(("showSettings:")), keyEquivalent: ",")
        menu.addItem(.separator())

        let services = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        menu.addItem(servicesItem)
        NSApp.servicesMenu = services

        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthers)
        menu.addItem(
            withTitle: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private static func fileMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "File")
        menu.addItem(withTitle: "Open…", action: Selector(("openLocation:")), keyEquivalent: "o")
        menu.addItem(.separator())

        // 7zFM's toolbar verbs. Its own accelerators are F-keys, which are fn-key
        // hostages on Mac laptops; the Finder preset uses Command chords instead and
        // the "7-Zip Classic" keymap adds the F-keys alongside. See docs/SHORTCUTS.md.
        let add = NSMenuItem(title: "Add to Archive…", action: Selector(("addAction:")), keyEquivalent: "a")
        add.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(add)
        menu.addItem(withTitle: "Extract…", action: Selector(("extractAction:")), keyEquivalent: "e")
        menu.addItem(withTitle: "Test Archive", action: Selector(("testAction:")), keyEquivalent: "t")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Get Info", action: Selector(("infoAction:")), keyEquivalent: "i")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private static func editMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Copy to Other Panel", action: Selector(("copyAction:")), keyEquivalent: "")
        menu.addItem(withTitle: "Move to Other Panel", action: Selector(("moveAction:")), keyEquivalent: "")
        menu.addItem(.separator())

        // Cmd+Delete is "move to Trash" on macOS, and on disk that is exactly what
        // Delete does here. Inside an archive it removes the member instead.
        let remove = NSMenuItem(
            title: "Delete",
            action: Selector(("deleteAction:")),
            keyEquivalent: keyEquivalent(NSBackspaceCharacter)
        )
        remove.keyEquivalentModifierMask = [.command]
        menu.addItem(remove)
        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private static func viewMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "View")
        // 7zFM uses F9 for this. F-keys are fn-key hostages on Mac laptops, so the
        // Finder preset binds Cmd+2; the Classic preset will add F9 alongside.
        menu.addItem(withTitle: "Toggle Two Panels", action: Selector(("toggleDualPane:")), keyEquivalent: "2")
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Enter Full Screen",
            action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f"
        )
        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private static func goMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Go")
        let up = NSMenuItem(
            title: "Enclosing Folder",
            action: Selector(("goBack:")),
            keyEquivalent: keyEquivalent(NSUpArrowFunctionKey)
        )
        up.keyEquivalentModifierMask = [.command]
        menu.addItem(up)

        let open = NSMenuItem(
            title: "Open Selection",
            action: Selector(("openSelection:")),
            keyEquivalent: keyEquivalent(NSDownArrowFunctionKey)
        )
        open.keyEquivalentModifierMask = [.command]
        menu.addItem(open)

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private static func windowMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        let item = NSMenuItem()
        item.submenu = menu
        NSApp.windowsMenu = menu
        return item
    }

    // MARK: Key equivalents

    /// The one-character key equivalent for an AppKit key constant.
    ///
    /// `NSUpArrowFunctionKey` and friends are `Int` code points in the Unicode private-use
    /// area, and `NSBackspaceCharacter` is plain C0 backspace; every one of them is a valid
    /// scalar, so the guard never fires. It is written as a guard rather than a force
    /// unwrap because an empty key equivalent - AppKit's own spelling for "no shortcut" -
    /// costs the user one keyboard shortcut, and a trap costs them the app.
    private static func keyEquivalent(_ codePoint: Int) -> String {
        guard let value = UInt32(exactly: codePoint), let scalar = UnicodeScalar(value) else {
            return ""
        }
        return String(scalar)
    }
}
