import Foundation

// MARK: - `recording/metadata.json`

public enum CaptureTargetMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case display = "display"
    case window = "window"
    case area = "area"
    case device = "device"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .display: return "Display"
        case .window: return "Window"
        case .area: return "Area"
        case .device: return "Device"
        }
    }

    public var systemImage: String {
        switch self {
        case .display: return "dock.rectangle"
        case .window: return "macwindow"
        case .area: return "viewfinder.rectangular"
        case .device: return "iphone"
        }
    }
}

public struct LogicalBounds: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct PixelDimensions: Codable, Equatable, Hashable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct CaptureTargetMetadata: Codable, Equatable, Hashable, Sendable {
    public var mode: CaptureTargetMode
    public var displayId: UInt32
    public var windowId: UInt32?
    public var appBundleId: String?
    public var appName: String?
    public var windowTitle: String?
    public var logicalBounds: LogicalBounds
    public var pixelSize: PixelDimensions
    public var scaleFactor: Double
    public var refreshRate: Double
    public var windowBorderRadius: Double

    public init(
        mode: CaptureTargetMode,
        displayId: UInt32,
        windowId: UInt32? = nil,
        appBundleId: String? = nil,
        appName: String? = nil,
        windowTitle: String? = nil,
        logicalBounds: LogicalBounds,
        pixelSize: PixelDimensions,
        scaleFactor: Double = 2.0,
        refreshRate: Double = 60.0,
        windowBorderRadius: Double = 16.0
    ) {
        self.mode = mode
        self.displayId = displayId
        self.windowId = windowId
        self.appBundleId = appBundleId
        self.appName = appName
        self.windowTitle = windowTitle
        self.logicalBounds = logicalBounds
        self.pixelSize = pixelSize
        self.scaleFactor = scaleFactor
        self.refreshRate = refreshRate
        self.windowBorderRadius = windowBorderRadius
    }
}

public struct RecordingTracksMetadata: Codable, Equatable, Hashable, Sendable {
    public var displayVideo: String
    public var webcamVideo: String?
    public var microphoneAudio: String?
    public var systemAudio: String?
    public var cursorTelemetry: String
    public var clicksTelemetry: String
    public var keysTelemetry: String
    public var windowTelemetry: String?

    public init(
        displayVideo: String = "display.mp4",
        webcamVideo: String? = nil,
        microphoneAudio: String? = nil,
        systemAudio: String? = nil,
        cursorTelemetry: String = "telemetry/cursor.jsonl",
        clicksTelemetry: String = "telemetry/clicks.jsonl",
        keysTelemetry: String = "telemetry/keys.jsonl",
        windowTelemetry: String? = "telemetry/window.jsonl"
    ) {
        self.displayVideo = displayVideo
        self.webcamVideo = webcamVideo
        self.microphoneAudio = microphoneAudio
        self.systemAudio = systemAudio
        self.cursorTelemetry = cursorTelemetry
        self.clicksTelemetry = clicksTelemetry
        self.keysTelemetry = keysTelemetry
        self.windowTelemetry = windowTelemetry
    }
}

public struct RecordingMetadata: Codable, Equatable, Hashable, Sendable {
    public var formatVersion: String
    public var appVersion: String
    public var platform: String
    public var createdAt: String
    public var durationMs: Double
    public var captureTarget: CaptureTargetMetadata
    public var tracks: RecordingTracksMetadata

    public init(
        formatVersion: String = "1.0.0",
        appVersion: String = "1.0.0",
        platform: String = "macos",
        createdAt: String = ISO8601DateFormatter().string(from: Date()),
        durationMs: Double,
        captureTarget: CaptureTargetMetadata,
        tracks: RecordingTracksMetadata = RecordingTracksMetadata()
    ) {
        self.formatVersion = formatVersion
        self.appVersion = appVersion
        self.platform = platform
        self.createdAt = createdAt
        self.durationMs = durationMs
        self.captureTarget = captureTarget
        self.tracks = tracks
    }
}

// MARK: - Telemetry `.jsonl` Line Models

public struct CursorSampleEvent: Codable, Equatable, Sendable {
    public var t: Double
    public var x: Double
    public var y: Double
    public var c: String

    public init(t: Double, x: Double, y: Double, c: String = "arrow") {
        self.t = t
        self.x = x
        self.y = y
        self.c = c
    }
}

public struct ClickEvent: Codable, Equatable, Sendable {
    public var t: Double
    public var type: String // "down" | "up" | "scroll"
    public var button: String? // "left" | "right" | "other"
    public var x: Double
    public var y: Double
    public var count: Int?
    public var dx: Double?
    public var dy: Double?

    public init(
        t: Double,
        type: String,
        button: String? = "left",
        x: Double,
        y: Double,
        count: Int? = 1,
        dx: Double? = nil,
        dy: Double? = nil
    ) {
        self.t = t
        self.type = type
        self.button = button
        self.x = x
        self.y = y
        self.count = count
        self.dx = dx
        self.dy = dy
    }
}

public struct KeyStrokeEvent: Codable, Equatable, Sendable {
    public var t: Double
    public var kind: String // "typing" | "shortcut"
    public var modifiers: [String]?
    public var key: String?
    public var label: String?

    public init(t: Double, kind: String, modifiers: [String]? = nil, key: String? = nil, label: String? = nil) {
        self.t = t
        self.kind = kind
        self.modifiers = modifiers
        self.key = key
        self.label = label
    }
}

// MARK: - JSON Lines (`.jsonl`) Reader & Append-Only Writer

public enum JSONLinesCodec {
    public static func load<T: Decodable>(_ type: T.Type, from url: URL) -> [T] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        var results: [T] = []
        content.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
            if let item = try? decoder.decode(T.self, from: data) {
                results.append(item)
            }
        }
        return results
    }
}

public final class JSONLinesAppender {
    private let fileHandle: FileHandle?
    private let encoder = JSONEncoder()
    private let lock = NSLock()

    public init(fileURL: URL) {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        self.fileHandle = try? FileHandle(forWritingTo: fileURL)
        try? self.fileHandle?.seekToEnd()
    }

    public func append<T: Encodable>(_ event: T) {
        lock.lock()
        defer { lock.unlock() }
        guard let handle = fileHandle,
              var data = try? encoder.encode(event) else { return }
        data.append(0x0A) // '\n'
        try? handle.write(contentsOf: data)
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        try? fileHandle?.synchronize()
        try? fileHandle?.close()
    }
}
