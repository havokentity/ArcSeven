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

        let services = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        menu.addItem(servicesItem)
        NSApp.servicesMenu = services

        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthers)
        menu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
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
        menu.addItem(withTitle: "Extract…", action: Selector(("extractAction:")), keyEquivalent: "e")
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
        menu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private static func goMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Go")
        let up = NSMenuItem(title: "Enclosing Folder", action: Selector(("goBack:")), keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!))
        up.keyEquivalentModifierMask = [.command]
        menu.addItem(up)

        let open = NSMenuItem(title: "Open Selection", action: Selector(("openSelection:")), keyEquivalent: String(UnicodeScalar(NSDownArrowFunctionKey)!))
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
}
