import AppKit
import Carbon.HIToolbox

/// Carbon の RegisterEventHotKey で登録するグローバルショートカット。アクセシビリティ権限はいらない。
@MainActor
final class HotKeyCenter {
    struct Binding: Equatable {
        var keyCode: UInt32
        var modifiers: UInt32
        var label: String
    }

    enum Action: UInt32, CaseIterable {
        case editNorthStar = 1, addTask, focusNote, toggleHidden, toggleClickThrough

        var title: String {
            switch self {
            case .editNorthStar: "クイック編集（北極星）"
            case .addTask: "クイック編集（追加）"
            case .focusNote: "付箋を操作する"
            case .toggleHidden: "付箋を隠す / 表示する"
            case .toggleClickThrough: "クリック透過を切り替える"
            }
        }

        var defaultBinding: Binding {
            let mods = UInt32(controlKey | optionKey)
            switch self {
            case .editNorthStar: return Binding(keyCode: UInt32(kVK_ANSI_P), modifiers: mods, label: "⌃⌥P")
            case .addTask: return Binding(keyCode: UInt32(kVK_ANSI_N), modifiers: mods, label: "⌃⌥N")
            case .focusNote: return Binding(keyCode: UInt32(kVK_ANSI_O), modifiers: mods, label: "⌃⌥O")
            case .toggleHidden: return Binding(keyCode: UInt32(kVK_ANSI_H), modifiers: mods, label: "⌃⌥H")
            case .toggleClickThrough: return Binding(keyCode: UInt32(kVK_ANSI_T), modifiers: mods, label: "⌃⌥T")
            }
        }
    }

    static let shared = HotKeyCenter()
    private var refs: [Action: EventHotKeyRef] = [:]
    private var handlers: [Action: () -> Void] = [:]
    private var handlerInstalled = false
    /// 登録できなかったもの（ほかのアプリが使っている）。
    private(set) var conflicts: Set<Action> = []

    func register(_ action: Action, handler: @escaping () -> Void) {
        installHandlerIfNeeded()
        handlers[action] = handler
        if let old = refs[action] { UnregisterEventHotKey(old) }
        let binding = action.defaultBinding
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x504C5253), id: action.rawValue) // 'PLRS'
        let status = RegisterEventHotKey(binding.keyCode, binding.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs[action] = ref
            conflicts.remove(action)
        } else {
            conflicts.insert(action)
        }
    }

    fileprivate func fire(_ id: UInt32) {
        guard let action = Action(rawValue: id) else { return }
        handlers[action]?()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let id = hotKeyID.id
            // Carbon のイベントはメインスレッドで届く。
            MainActor.assumeIsolated { HotKeyCenter.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
