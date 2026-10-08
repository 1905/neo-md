import AppKit

/// The main menu, built in code (the app has no nib).
/// Custom actions go through the responder chain:
/// `showSettings:` (handled by `AppDelegate`, so it works with no document window), `showFind:`, `selectTab:` (tag = `DocTab.rawValue`), `toggleOutline:`, `renderNow:`.
@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenuItem(appMenu()))
        main.addItem(submenuItem(fileMenu()))
        main.addItem(submenuItem(editMenu()))
        main.addItem(submenuItem(viewMenu()))
        let window = windowMenu()
        main.addItem(submenuItem(window))
        NSApplication.shared.windowsMenu = window
        return main
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "neo-md")
        menu.addItem(item("About neo-md", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(AppDelegate.showSettings(_:)), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("Hide neo-md", #selector(NSApplication.hide(_:)), key: "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), key: "h",
                          modifiers: [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit neo-md", #selector(NSApplication.terminate(_:)), key: "q"))
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(item("Open…", #selector(NSDocumentController.openDocument(_:)), key: "o"))

        let recent = NSMenu(title: "Open Recent")
        recent.addItem(item("Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:))))
        // Private selector: lets AppKit manage the recent list in a nib-less app.
        // If it is missing, the File menu still works without Open Recent entries.
        let setMenuName = NSSelectorFromString("_setMenuName:")
        if recent.responds(to: setMenuName) {
            recent.perform(setMenuName, with: "NSRecentDocumentsMenu" as NSString)
        }
        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recentItem.submenu = recent
        menu.addItem(recentItem)

        menu.addItem(.separator())
        menu.addItem(item("Close", #selector(NSWindow.performClose(_:)), key: "w"))
        menu.addItem(item("Save", #selector(NSDocument.save(_:)), key: "s"))
        menu.addItem(item("Revert to Saved", #selector(NSDocument.revertToSaved(_:))))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", Selector(("undo:")), key: "z"))
        menu.addItem(item("Redo", Selector(("redo:")), key: "z", modifiers: [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), key: "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), key: "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), key: "v"))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), key: "a"))
        menu.addItem(.separator())
        menu.addItem(item("Find…", Selector(("showFind:")), key: "f"))
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        let tabs: [(String, DocTab, String)] = [("Render", .render, "1"), ("Raw", .raw, "2"), ("Split", .split, "3")]
        for (title, tab, key) in tabs {
            let tabItem = item(title, Selector(("selectTab:")), key: key)
            tabItem.tag = tab.rawValue
            menu.addItem(tabItem)
        }
        menu.addItem(.separator())
        menu.addItem(item("Hide Outline", Selector(("toggleOutline:")), key: "o", modifiers: [.command, .shift]))
        menu.addItem(item("Render Now", Selector(("renderNow:")), key: "r"))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    private static func submenuItem(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector, key: String = "",
                             modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
        return item
    }
}
