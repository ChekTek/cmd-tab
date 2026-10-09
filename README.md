# CmdTab

A minimal ⌘⇥ replacement for macOS that switches between **windows** (not apps) and shows a
thumbnail of each one. No settings, no menu bar item, nothing to configure.

- `⌘⇥` opens the switcher and moves forward, `⌘⇧⇥` moves backward, `←`/`→` also work.
- Release `⌘` to switch to the highlighted window, `Esc` to cancel, `W` to close the highlighted
  window (or quit its app when that was its last window), `H` to hide its app. Hovering highlights a window
  and clicking it switches too.
- Windows are ordered most-recently-used first, including minimized windows, windows on other
  Spaces and windows of hidden apps.
- Starts at login (registers itself as a login item the first time it runs from `~/Applications`).

## Build and install

```bash
make install
```

This builds a release binary, wraps it in `build/CmdTab.app`, signs it with your "Apple Development"
certificate, copies it to `~/Applications` and launches it. Sign with something else via
`make install SIGN_ID="..."`; `SIGN_ID=-` ad-hoc signs, but then every rebuild counts as a new app
and the permissions below have to be granted again.

## Permissions

On first launch macOS asks for two permissions. Both go to this app only; there is no other code
involved.

1. **Accessibility** (System Settings › Privacy & Security › Accessibility). Needed to intercept ⌘⇥
   before the Dock sees it and to raise the chosen window. The app starts working as soon as it is
   granted.
2. **Screen Recording**. Needed for the thumbnails; macOS also hides window titles from apps
   without it. macOS only honors this grant after a restart, so the app relaunches itself once it
   sees the permission land. Since macOS 15 the system re-confirms this permission with a dialog
   about once a month.

## How it works

- `EventTap.swift`: a session-level `CGEventTap` swallows ⌘⇥ / ⌘⇧⇥ and, while the switcher is up,
  every other key. Letting go of ⌘ commits.
- `Private.swift`: the Dock matches ⌘⇥ inside the WindowServer, ahead of any event tap, so the two
  system hotkeys (ids 1 and 2) are disabled with the private `CGSSetSymbolicHotKeyEnabled` while
  the app runs and re-enabled when it quits. If the app ever dies without doing that, `make restore`
  puts the native ⌘⇥ back.
- `Windows.swift`: `CGWindowListCopyWindowInfo` provides the front-to-back order, the Accessibility
  API filters it down to real windows (popups, tooltips and closed-but-retained windows are dropped)
  and provides the element used to raise a window.
- `Capture.swift`: `SCScreenshotManager` grabs a still of each window at 2x thumbnail size,
  concurrently, each time the switcher opens. The last image per window is kept so the next ⌘⇥
  shows something immediately.
- `SwitcherPanel.swift`: a non-activating `NSPanel` hosting a small SwiftUI grid.

`CmdTab --list` prints the windows the switcher would show, in order.

## License

MIT, see [LICENSE](LICENSE).
