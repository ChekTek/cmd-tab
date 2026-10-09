import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let switcher = SwitcherPanel()
    private let tap = HotKeyTap()
    private var permissionTimer: Timer?
    private var screenTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerAsLoginItem()
        requestScreenRecording()
        if accessibilityTrusted(prompt: true) {
            start()
        } else {
            NSLog("Waiting for Accessibility permission (System Settings > Privacy & Security > Accessibility)")
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self, self.accessibilityTrusted(prompt: false) else { return }
                    timer.invalidate()
                    self.start()
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NativeCmdTab.setEnabled(true)
    }

    private func start() {
        tap.isActive = { [switcher] in switcher.isVisible }
        tap.onTab = { [weak self] reverse in self?.tabPressed(reverse: reverse) }
        tap.onMove = { [switcher] delta in switcher.move(by: delta) }
        tap.onCommit = { [weak self] in self?.commit() }
        tap.onCancel = { [switcher] in switcher.hide() }
        tap.onClose = { [weak self] in self?.closeSelected() }
        switcher.model.onPick = { [weak self] index in
            self?.switcher.model.selection = index
            self?.commit()
        }
        guard tap.start() else {
            NSLog("Could not create the event tap; is Accessibility granted?")
            return
        }
        NativeCmdTab.setEnabled(false)
        NSLog("CmdTab running")

        AXWindows.warmUp()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.activationPolicy == .regular
            else { return }
            // Give the app a moment to bring up its accessibility server before the first contact.
            let pid = app.processIdentifier
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { AXWindows.warmUp(pid: pid) }
        }
    }

    private func tabPressed(reverse: Bool) {
        if switcher.isVisible {
            switcher.move(by: reverse ? -1 : 1)
            return
        }
        let windows = WindowList.current()
        guard !windows.isEmpty else { return }
        let start = windows.count == 1 ? 0 : (reverse ? windows.count - 1 : 1)
        switcher.show(windows: windows, selection: start)
    }

    private func closeSelected() {
        guard let selected = switcher.selectedWindow else { return }
        let closed = WindowCloser.close(selected, allWindows: switcher.model.windows)
        switcher.remove(closed)
    }

    private func commit() {
        let selected = switcher.selectedWindow
        switcher.hide()
        // Off the main thread: un-minimizing through Accessibility blocks until the app's animation
        // finishes, which would keep the panel on screen (and the event tap stalled) until then.
        if let selected {
            DispatchQueue.global(qos: .userInteractive).async {
                WindowActivator.activate(selected)
            }
        }
    }

    private func accessibilityTrusted(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// macOS only honors a new Screen Recording grant after the app restarts, so relaunch once it lands.
    private func requestScreenRecording() {
        guard !CGPreflightScreenCaptureAccess() else { return }
        NSLog("Requesting Screen Recording permission")
        CGRequestScreenCaptureAccess()
        screenTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { timer in
            guard CGPreflightScreenCaptureAccess() else { return }
            timer.invalidate()
            NSLog("Screen Recording granted; relaunching")
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        }
    }

    /// Only register when running from an Applications folder, so a build-directory copy never becomes the login item.
    private func registerAsLoginItem() {
        let path = Bundle.main.bundlePath
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/") else { return }
        guard SMAppService.mainApp.status != .enabled else { return }
        do {
            try SMAppService.mainApp.register()
        } catch {
            NSLog("Login item registration failed: \(error)")
        }
    }
}

// `--restore` re-enables the native ⌘⇥ in case a previous run crashed before doing so.
if CommandLine.arguments.contains("--restore") {
    NativeCmdTab.setEnabled(true)
    exit(0)
}

// `--list` prints the windows the switcher would show, in order, for debugging the filter.
if CommandLine.arguments.contains("--list") {
    for w in WindowList.current() {
        let state = w.isOnScreen ? "on " : (w.isMinimized ? "min" : "off")
        print("\(w.id)\t\(state)\t\(w.appName)\t\(w.title)\t\(Int(w.bounds.width))x\(Int(w.bounds.height))")
    }
    exit(0)
}

// Restore the native ⌘⇥ on SIGTERM/SIGINT as well (e.g. `pkill CmdTab`, Ctrl-C).
let signalSources: [DispatchSourceSignal] = [SIGTERM, SIGINT].map { sig in
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { NSApp.terminate(nil) }
    source.resume()
    return source
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
