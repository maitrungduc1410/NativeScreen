import AppKit

/// Renders a native macOS progress bar on the application's `NSDockTile`,
/// which automatically appears both on the macOS Dock icon AND in the `⌘ + Tab` App Switcher!
@MainActor
public final class DockProgressIndicatingController {
    public static let shared = DockProgressIndicatingController()

    private var tileView: DockTileProgressView?

    private init() {}

    /// Updates the Dock & `⌘+Tab` progress bar (`0.0 ... 1.0`). Pass `nil` to hide the progress bar.
    public func setProgress(_ progress: Double?) {
        let dockTile = NSApplication.shared.dockTile

        guard let value = progress else {
            dockTile.contentView = nil
            tileView = nil
            dockTile.display()
            return
        }

        let clamped = max(0.0, min(1.0, value))
        if tileView == nil {
            let size = dockTile.size
            let view = DockTileProgressView(frame: NSRect(origin: .zero, size: size))
            dockTile.contentView = view
            self.tileView = view
        }

        tileView?.progress = CGFloat(clamped)
        dockTile.display()
    }
}

private final class DockTileProgressView: NSView {
    var progress: CGFloat = 0.0 {
        didSet {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // 1. Draw the application icon full-size
        if let appIcon = NSApplication.shared.applicationIconImage {
            appIcon.draw(in: bounds)
        }

        // 2. Draw macOS Dock-style pill progress bar along the bottom
        let barWidth = bounds.width * 0.84
        let barHeight = max(8.0, bounds.height * 0.095)
        let barX = (bounds.width - barWidth) * 0.5
        let barY = bounds.height * 0.055
        let trackRect = NSRect(x: barX, y: barY, width: barWidth, height: barHeight)
        let radius = barHeight * 0.5

        // Dark translucent track background with crisp light border
        let trackPath = NSBezierPath(roundedRect: trackRect, xRadius: radius, yRadius: radius)
        NSColor(white: 0.06, alpha: 0.82).setFill()
        trackPath.fill()

        NSColor(white: 0.72, alpha: 0.88).setStroke()
        trackPath.lineWidth = max(1.2, bounds.width * 0.014)
        trackPath.stroke()

        // Inner blue progress fill
        let inset: CGFloat = max(1.6, bounds.width * 0.016)
        let innerTrack = trackRect.insetBy(dx: inset, dy: inset)
        let fillWidth = max(innerTrack.height, innerTrack.width * max(0.04, min(1.0, progress)))
        let fillRect = NSRect(
            x: innerTrack.minX,
            y: innerTrack.minY,
            width: min(innerTrack.width, fillWidth),
            height: innerTrack.height
        )
        let fillRadius = innerTrack.height * 0.5
        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: fillRadius, yRadius: fillRadius)

        NSColor(red: 0.25, green: 0.62, blue: 1.0, alpha: 1.0).setFill()
        fillPath.fill()
    }
}
