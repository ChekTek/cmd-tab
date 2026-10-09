import AppKit
import ApplicationServices

struct WindowInfo: Identifiable {
    let id: CGWindowID
    let pid: pid_t
    let title: String
    let appName: String
    /// Window-server coordinates: origin at the top-left of the primary display.
    let bounds: CGRect
    let isOnScreen: Bool
    let isMinimized: Bool
    /// The Accessibility element for the window, when its app answered. Used to raise it.
    let axElement: AXUIElement?
}

/// Accessibility view of an app's windows. CoreGraphics lists every window-server surface, including
/// popups, tooltips and windows an app closed but kept around; Accessibility only lists real windows.
enum AXWindows {
    struct Entry {
        let element: AXUIElement
        let isMinimized: Bool
    }

    /// Standard windows and dialogs of an app, keyed by window ID. `nil` when the app did not answer
    /// (crashed, hung, or not yet accessible), in which case callers fall back to heuristics.
    static func realWindows(of pid: pid_t) -> [CGWindowID: Entry]? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement]
        else { return nil }

        var result: [CGWindowID: Entry] = [:]
        for element in elements {
            var id: CGWindowID = 0
            guard _AXUIElementGetWindow(element, &id) == .success else { continue }
            var subrole: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
            guard let subrole = subrole as? String,
                  subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole
            else { continue }
            var minimized: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &minimized)
            result[id] = Entry(element: element, isMinimized: minimized as? Bool ?? false)
        }
        return result
    }

    /// The first query to an app takes ~20ms while the connection is set up; later ones take well under
    /// a millisecond. Querying every app once up front keeps ⌘⇥ fast.
    static func warmUp(pid: pid_t? = nil) {
        if let pid {
            _ = realWindows(of: pid)
            return
        }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            _ = realWindows(of: app.processIdentifier)
        }
    }
}

enum WindowList {
    /// Switchable windows, most-recently-used first (approximately): on-screen windows in the window
    /// server's front-to-back order, followed by minimized windows, windows on other Spaces and windows
    /// of hidden apps. The "all windows" list is in creation order, so it is only used for that tail.
    static func current() -> [WindowInfo] {
        var enumerator = Enumerator()
        let onScreen = enumerator.windows(options: [.optionOnScreenOnly, .excludeDesktopElements])
        let seen = Set(onScreen.map(\.id))
        let offScreen = enumerator.windows(options: [.optionAll, .excludeDesktopElements])
            .filter { !seen.contains($0.id) }
        return onScreen + offScreen
    }

    private struct Enumerator {
        private let me = getpid()
        private var apps: [pid_t: NSRunningApplication] = [:]
        private var axByPid: [pid_t: [CGWindowID: AXWindows.Entry]?] = [:]

        private mutating func axWindows(of pid: pid_t) -> [CGWindowID: AXWindows.Entry]? {
            if let cached = axByPid[pid] { return cached }
            let result = AXWindows.realWindows(of: pid)
            axByPid[pid] = result
            return result
        }

        mutating func windows(options: CGWindowListOption) -> [WindowInfo] {
            guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
                return []
            }
            var result: [WindowInfo] = []
            for entry in raw {
                guard (entry[kCGWindowLayer as String] as? Int) == 0,
                      let id = entry[kCGWindowNumber as String] as? CGWindowID,
                      let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                      pid != me,
                      (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                      let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                      let bounds = CGRect(dictionaryRepresentation: boundsDict),
                      bounds.width >= 80, bounds.height >= 40
                else { continue }

                let app = apps[pid] ?? NSRunningApplication(processIdentifier: pid)
                guard let app, app.activationPolicy == .regular else { continue }
                apps[pid] = app

                let title = entry[kCGWindowName as String] as? String ?? ""
                let onScreen = entry[kCGWindowIsOnscreen as String] as? Bool ?? false
                var isMinimized = false
                var axElement: AXUIElement?
                if let axWindows = axWindows(of: pid) {
                    // The app answered: only windows it reports as real windows count.
                    guard let ax = axWindows[id] else { continue }
                    isMinimized = ax.isMinimized
                    axElement = ax.element
                } else {
                    // Fallback heuristics. Off-screen windows without a title are almost always hidden
                    // helper windows (Chrome, Electron, ...). Off-screen windows that belong to no Space
                    // were closed by their app but kept around (Qt and Electron apps do this).
                    guard onScreen || (!title.isEmpty && WindowSpaces.belongsToAnySpace(id)) else { continue }
                }

                let appName = app.localizedName ?? ""
                result.append(WindowInfo(
                    id: id,
                    pid: pid,
                    title: title.isEmpty ? appName : title,
                    appName: appName,
                    bounds: bounds,
                    isOnScreen: onScreen,
                    isMinimized: isMinimized,
                    axElement: axElement
                ))
            }
            return result
        }
    }
}

enum WindowCloser {
    /// Closes the window, or quits its app when this is the app's last window.
    /// Returns the IDs of the windows that are going away.
    static func close(_ window: WindowInfo, allWindows: [WindowInfo]) -> Set<CGWindowID> {
        let siblings = allWindows.filter { $0.pid == window.pid }
        let app = NSRunningApplication(processIdentifier: window.pid)
        // Finder never quits, so its last window is just closed like any other.
        if siblings.count == 1, let app, app.bundleIdentifier != "com.apple.finder", app.terminate() {
            return Set(siblings.map(\.id))
        }
        let element = window.axElement ?? AXWindows.realWindows(of: window.pid)?[window.id]?.element
        guard let element else { return [] }
        var button: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &button) == .success,
              let button, AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success
        else { return [] }
        return [window.id]
    }
}

enum WindowActivator {
    /// Un-minimizes and raises the window through the Accessibility API, then activates its app.
    /// Raising first makes that window the app's front window, so activation brings it to the top.
    static func activate(_ window: WindowInfo) {
        let element = window.axElement ?? AXWindows.realWindows(of: window.pid)?[window.id]?.element
        if let element {
            if window.isMinimized {
                AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        }
        let activated = NSRunningApplication(processIdentifier: window.pid)?.activate() ?? false
        if !activated {
            NSLog("Activating \(window.appName) was refused")
        }
    }
}
