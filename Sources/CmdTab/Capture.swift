import AppKit
import ScreenCaptureKit

/// Captures window thumbnails with ScreenCaptureKit and keeps the latest image per window.
/// Each window is captured once per opening. Images are kept between openings so the switcher
/// shows the previous still immediately and replaces it as soon as the new one arrives.
@MainActor
final class ThumbnailStore: ObservableObject {
    @Published private(set) var images: [CGWindowID: CGImage] = [:]

    /// Pixel size cap for captures. Thumbnails are drawn at 300x190 points, so 2x keeps them crisp on Retina.
    nonisolated private static let maxPixelSize = CGSize(width: 600, height: 380)

    private var generation = 0
    private var content: SCShareableContent?

    /// Captures a still of each window. Cancelled by `stop()` or the next `start`.
    func start(_ windows: [WindowInfo]) {
        generation += 1
        let gen = generation
        let ids = Set(windows.map(\.id))
        images = images.filter { ids.contains($0.key) }

        Task {
            // First round with whatever content list we already have, so stale-but-instant beats nothing.
            if let cached = content {
                await captureAll(windows, from: cached, generation: gen)
            }
            guard gen == generation else { return }
            do {
                content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            } catch {
                NSLog("ScreenCaptureKit content unavailable (is Screen Recording granted?): \(error)")
                return
            }
            if let content {
                await captureAll(windows, from: content, generation: gen)
            }
        }
    }

    func stop() {
        generation += 1
    }

    private func captureAll(_ windows: [WindowInfo], from content: SCShareableContent, generation gen: Int) async {
        let byID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
            for window in windows {
                guard let sc = byID[window.id] else { continue }
                let frame = sc.frame
                group.addTask { (window.id, await Self.capture(sc, frame: frame)) }
            }
            for await (id, image) in group {
                guard gen == generation, let image else { continue }
                images[id] = image
            }
        }
    }

    nonisolated private static func capture(_ window: SCWindow, frame: CGRect) async -> CGImage? {
        guard frame.width > 0, frame.height > 0 else { return nil }
        let scale = min(maxPixelSize.width / frame.width, maxPixelSize.height / frame.height, 2)
        let config = SCStreamConfiguration()
        config.width = Int(frame.width * scale)
        config.height = Int(frame.height * scale)
        config.scalesToFit = true
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.captureResolution = .automatic
        let filter = SCContentFilter(desktopIndependentWindow: window)
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}
