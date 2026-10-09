import ApplicationServices
import CoreGraphics

/// Private HIServices call: maps an accessibility window element to its CGWindowID.
/// Needed to match the window the user picked to the AX element we can raise.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Private SkyLight call (re-exported through CoreGraphics). Toggles a system "symbolic hotkey".
/// The Dock matches ⌘⇥ (id 1) and ⌘⇧⇥ (id 2) inside the WindowServer, ahead of any app's event tap,
/// so they have to be switched off for us to see the keystrokes at all.
/// The effect persists after the process exits, so it must be re-enabled on quit.
@_silgen_name("CGSSetSymbolicHotKeyEnabled") @discardableResult
func CGSSetSymbolicHotKeyEnabled(_ hotKey: Int32, _ isEnabled: Bool) -> CGError

enum NativeCmdTab {
    private static let hotKeys: [Int32] = [1, 2]

    static func setEnabled(_ enabled: Bool) {
        for key in hotKeys {
            CGSSetSymbolicHotKeyEnabled(key, enabled)
        }
    }
}

/// Private SkyLight calls used to tell real off-screen windows (other Space, minimized, hidden app)
/// apart from windows an app closed but kept around: the latter belong to no Space at all.
@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> UInt32

/// `mask` 7 = all Spaces. Returns the Space IDs the given windows belong to.
@_silgen_name("CGSCopySpacesForWindows")
func CGSCopySpacesForWindows(_ cid: UInt32, _ mask: Int, _ windowIDs: CFArray) -> CFArray?

enum WindowSpaces {
    private static let connection = CGSMainConnectionID()

    static func belongsToAnySpace(_ id: CGWindowID) -> Bool {
        let spaces = CGSCopySpacesForWindows(connection, 7, [id] as CFArray) as? [UInt64] ?? []
        return !spaces.isEmpty
    }
}
