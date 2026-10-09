import AppKit

/// Session-level active event tap. Swallows ⌘⇥ / ⌘⇧⇥ and, while the switcher is open, every other key.
/// Requires the Accessibility permission.
@MainActor
final class HotKeyTap {
    var onTab: (_ reverse: Bool) -> Void = { _ in }
    var onMove: (_ delta: Int) -> Void = { _ in }
    var onCommit: () -> Void = {}
    var onCancel: () -> Void = {}
    var onClose: () -> Void = {}
    var onHide: () -> Void = {}
    var isActive: () -> Bool = { false }

    private var tap: CFMachPort?

    // Virtual key codes (kVK_* in Carbon's Events.h).
    private static let tabKey = 48
    private static let escapeKey = 53
    private static let leftArrowKey = 123
    private static let rightArrowKey = 124
    private static let wKey = 13
    private static let hKey = 4

    func start() -> Bool {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let tap = Unmanaged<HotKeyTap>.fromOpaque(refcon!).takeUnretainedValue()
            return MainActor.assumeIsolated { tap.handle(type, event) }
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }

        let flags = event.flags
        let command = flags.contains(.maskCommand)
        let active = isActive()

        // Any event without ⌘ while open means the user let go: switch to the selection.
        if active, !command {
            onCommit()
            return pass
        }

        let key = Int(event.getIntegerValueField(.keyboardEventKeycode))
        switch type {
        case .keyDown:
            let otherModifiers = flags.intersection([.maskControl, .maskAlternate])
            if key == Self.tabKey, command, otherModifiers.isEmpty {
                onTab(flags.contains(.maskShift))
                return nil
            }
            guard active else { return pass }
            switch key {
            case Self.escapeKey: onCancel()
            case Self.leftArrowKey: onMove(-1)
            case Self.rightArrowKey: onMove(1)
            case Self.wKey: onClose()
            case Self.hKey: onHide()
            default: break
            }
            return nil
        case .keyUp:
            if key == Self.tabKey, command { return nil }
            return active ? nil : pass
        default:
            return pass
        }
    }
}
