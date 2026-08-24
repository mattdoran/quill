import AppKit

@MainActor
final class ApplicationMenuController: NSObject {
    var onQuit: (() -> Void)?

    func install() {
        let main = NSMenu()
        main.addItem(menuItem(title: "Quill", submenu: applicationMenu()))
        main.addItem(menuItem(title: "File", submenu: fileMenu()))
        main.addItem(menuItem(title: "Edit", submenu: editMenu()))
        main.addItem(menuItem(title: "Window", submenu: windowMenu()))
        NSApp.mainMenu = main
    }

    private func applicationMenu() -> NSMenu {
        let menu = NSMenu(title: "Quill")
        let about = NSMenuItem(
            title: "About Quill",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        about.target = NSApp
        menu.addItem(about)
        menu.addItem(.separator())
        menu.addItem(applicationItem("Hide Quill", #selector(NSApplication.hide(_:)), "h"))
        let hideOthers = applicationItem(
            "Hide Others",
            #selector(NSApplication.hideOtherApplications(_:)),
            "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthers)
        menu.addItem(applicationItem(
            "Show All",
            #selector(NSApplication.unhideAllApplications(_:)),
            ""
        ))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Quill", action: #selector(quitClicked), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    private func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(NSMenuItem(
            title: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        ))
        return menu
    }

    private func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(NSMenuItem(title: "Undo", action: #selector(UndoManager.undo), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: #selector(UndoManager.redo), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        menu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        menu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        menu.addItem(NSMenuItem(
            title: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        ))
        return menu
    }

    private func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(NSMenuItem(
            title: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        ))
        menu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        return menu
    }

    private func applicationItem(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = NSApp
        return item
    }

    private func menuItem(title: String, submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    @objc private func quitClicked() {
        onQuit?()
    }
}
