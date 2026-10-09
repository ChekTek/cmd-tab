import AppKit
import SwiftUI

@MainActor
final class SwitcherModel: ObservableObject {
    @Published var windows: [WindowInfo] = []
    @Published var selection = 0
    @Published var columns = 1
    /// Called with the index of a clicked window.
    var onPick: ((Int) -> Void)?
    /// Where the pointer was when the switcher opened. The panel usually appears under a resting
    /// pointer, which must not steal the selection from the keyboard; only real movement counts.
    var mouseAtOpen = CGPoint.zero
    var mouseMoved = false

    func noteMouse(at point: CGPoint) {
        guard !mouseMoved else { return }
        mouseMoved = hypot(point.x - mouseAtOpen.x, point.y - mouseAtOpen.y) > 4
    }
    let thumbnails = ThumbnailStore()
    private var icons: [pid_t: NSImage] = [:]

    func icon(for pid: pid_t) -> NSImage? {
        if let icon = icons[pid] { return icon }
        let icon = NSRunningApplication(processIdentifier: pid)?.icon
        icons[pid] = icon
        return icon
    }
}

enum Metrics {
    static let thumbnail = CGSize(width: 300, height: 190)
    static let headerHeight: CGFloat = 20
    static let cellPadding: CGFloat = 8
    static let spacing: CGFloat = 12
    static let panelPadding: CGFloat = 16

    static var cellSize: CGSize {
        CGSize(width: thumbnail.width + cellPadding * 2,
               height: headerHeight + 6 + thumbnail.height + cellPadding * 2)
    }

    static func panelSize(count: Int, columns: Int) -> CGSize {
        let rows = max(1, Int((Double(count) / Double(columns)).rounded(.up)))
        let cols = max(1, min(count, columns))
        return CGSize(
            width: CGFloat(cols) * cellSize.width + CGFloat(cols - 1) * spacing + panelPadding * 2,
            height: CGFloat(rows) * cellSize.height + CGFloat(rows - 1) * spacing + panelPadding * 2
        )
    }
}

@MainActor
final class SwitcherPanel {
    let model = SwitcherModel()
    private let panel: NSPanel
    private var screen: NSScreen?

    var isVisible: Bool { panel.isVisible }
    var selectedWindow: WindowInfo? {
        model.windows.indices.contains(model.selection) ? model.windows[model.selection] : nil
    }

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        let host = ClickThroughHostingView(rootView: SwitcherView(model: model, thumbnails: model.thumbnails))
        host.sizingOptions = []
        panel.contentView = host
    }

    func show(windows: [WindowInfo], selection: Int) {
        let screen = targetScreen(for: windows)
        self.screen = screen
        let usableWidth = screen.visibleFrame.width * 0.9 - Metrics.panelPadding * 2
        let columns = max(1, Int((usableWidth + Metrics.spacing) / (Metrics.cellSize.width + Metrics.spacing)))

        model.windows = windows
        model.selection = selection
        model.columns = columns
        model.mouseAtOpen = NSEvent.mouseLocation
        model.mouseMoved = false

        layout()
        panel.orderFrontRegardless()
        model.thumbnails.start(windows)
    }

    /// Drops windows from the open switcher (after closing them) and keeps the selection in place.
    func remove(_ ids: Set<CGWindowID>) {
        model.windows.removeAll { ids.contains($0.id) }
        guard !model.windows.isEmpty else {
            hide()
            return
        }
        model.selection = min(model.selection, model.windows.count - 1)
        layout()
    }

    private func layout() {
        guard let screen else { return }
        let size = Metrics.panelSize(count: model.windows.count, columns: model.columns)
        let origin = CGPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    func hide() {
        model.thumbnails.stop()
        panel.orderOut(nil)
    }

    func move(by delta: Int) {
        let count = model.windows.count
        guard count > 0 else { return }
        model.selection = ((model.selection + delta) % count + count) % count
    }

    /// The screen holding the frontmost window, falling back to the screen under the mouse.
    private func targetScreen(for windows: [WindowInfo]) -> NSScreen {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return NSScreen.main! }
        if let front = windows.first(where: \.isOnScreen) {
            // Window-server coordinates are top-left based; AppKit's are bottom-left based on the primary screen.
            let point = CGPoint(x: front.bounds.midX, y: primary.frame.height - front.bounds.midY)
            if let screen = screens.first(where: { $0.frame.contains(point) }) { return screen }
        }
        let mouse = NSEvent.mouseLocation
        return screens.first(where: { $0.frame.contains(mouse) }) ?? primary
    }
}

struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel
    @ObservedObject var thumbnails: ThumbnailStore

    private var rows: [[Int]] {
        stride(from: 0, to: model.windows.count, by: model.columns).map {
            Array($0 ..< min($0 + model.columns, model.windows.count))
        }
    }

    var body: some View {
        VStack(spacing: Metrics.spacing) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: Metrics.spacing) {
                    ForEach(row, id: \.self) { index in
                        cell(index)
                    }
                }
            }
        }
        .padding(Metrics.panelPadding)
        .background(
            VisualEffect()
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        )
    }

    private func cell(_ index: Int) -> some View {
        let window = model.windows[index]
        let selected = index == model.selection
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let icon = model.icon(for: window.pid) {
                    Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                }
                Text(window.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .frame(height: Metrics.headerHeight)

            ZStack {
                if let image = thumbnails.images[window.id] {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                } else if let icon = model.icon(for: window.pid) {
                    Image(nsImage: icon).resizable().frame(width: 96, height: 96)
                }
            }
            .frame(width: Metrics.thumbnail.width, height: Metrics.thumbnail.height)
        }
        .padding(Metrics.cellPadding)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? Color.white.opacity(0.12) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(selected ? Color.accentColor : .clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            guard case .active = phase else { return }
            model.noteMouse(at: NSEvent.mouseLocation)
            if model.mouseMoved { model.selection = index }
        }
        .onTapGesture { model.onPick?(index) }
    }
}

/// The panel never becomes key, so the first click must count as a click rather than as "activate me".
private final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
