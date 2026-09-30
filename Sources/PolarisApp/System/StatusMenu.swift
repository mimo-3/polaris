import AppKit
import PolarisCore

/// メニューバーのアイコンとメニュー。1行目で北極星が見えるので、隠しているあいだも確かめられる。
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private weak var app: AppCoordinator?

    init(app: AppCoordinator) {
        self.app = app
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        item.button?.setAccessibilityLabel("Polaris")
        updateIcon(hidden: false)
    }

    func updateIcon(hidden: Bool) {
        item.button?.image = Self.icon(hidden: hidden)
    }

    /// 16pt。1.25pt のリング ⌀14 の中心に ⌀5 の点。隠しているあいだはリングだけ。
    static func icon(hidden: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            let ring = NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 14, height: 14).insetBy(dx: 0.625, dy: 0.625))
            ring.lineWidth = 1.25
            NSColor.black.setStroke()
            ring.stroke()
            if !hidden {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: 5.5, y: 5.5, width: 5, height: 5)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let app else { return }
        menu.removeAllItems()
        let today = app.model.today

        let star = today.northStar.isEmpty ? Copy.northStarNone : today.northStar
        menu.addItem(disabled(star.count > 24 ? String(star.prefix(24)) + "…" : star))
        menu.addItem(disabled(today.mode.label))
        menu.addItem(.separator())

        let hidden = app.note.isHidden
        menu.addItem(action(hidden ? Copy.showNote : Copy.hideNote, key: "h") { $0.note.toggleVisibility() })
        menu.addItem(action(Copy.hide15) { $0.note.hide(for: 15) })
        let through = action(Copy.clickThrough, key: "t") { $0.note.setClickThrough(!$0.model.clickThrough) }
        through.state = app.model.clickThrough ? .on : .off
        menu.addItem(through)
        menu.addItem(.separator())

        menu.addItem(action(Copy.editNorthStar, key: "p") { $0.showQuickEdit(.northStar) })
        menu.addItem(action(Copy.addTask, key: "n") { $0.showQuickEdit(.add) })
        menu.addItem(action(Copy.redoMorning) { $0.showMorning(key: true) })

        let modes = NSMenu()
        for mode in app.model.modes {
            let entry = action(mode.label) { $0.model.setMode(mode.id) }
            entry.state = mode.id == today.mode.id ? .on : .off
            modes.addItem(entry)
        }
        menu.addItem(submenu(Copy.modeMenu, modes))

        let corners = NSMenu()
        for corner in Corner.menuOrder {
            let entry = action(corner.label) { $0.note.move(to: corner) }
            entry.state = corner == app.model.corner ? .on : .off
            corners.addItem(entry)
        }
        menu.addItem(submenu(Copy.cornerMenu, corners))
        menu.addItem(.separator())

        if app.model.loadFailed {
            menu.addItem(action(Copy.resetState) { $0.model.resetCorruptState() })
            menu.addItem(.separator())
        }
        let settings = action(Copy.settings) { $0.showSettings() }
        settings.keyEquivalent = ","
        settings.keyEquivalentModifierMask = .command
        menu.addItem(settings)
        let quit = action(Copy.quit) { _ in NSApp.terminate(nil) }
        quit.keyEquivalent = "q"
        quit.keyEquivalentModifierMask = .command
        menu.addItem(quit)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    /// ⌃⌥ のショートカット表記を右に出す（実際の登録は HotKeyCenter）。
    private func action(_ title: String, key: String? = nil, _ run: @escaping (AppCoordinator) -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title) { [weak self] in
            guard let app = self?.app else { return }
            run(app)
        }
        if let key {
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = [.control, .option]
        }
        return item
    }
}

@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
