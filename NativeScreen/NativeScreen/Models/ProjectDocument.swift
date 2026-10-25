import Foundation
import CoreGraphics

// MARK: - Normalized Primitives ([0.0, 1.0] Cross-Platform Coordinates)

public struct Point01: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let center = Point01(x: 0.5, y: 0.5)
    public static let zero = Point01(x: 0.0, y: 0.0)
    public static let one = Point01(x: 1.0, y: 1.0)
}

public struct Rect01: Codable, Equatable, Hashable, Sendable {
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

    public static let full = Rect01(x: 0.0, y: 0.0, width: 1.0, height: 1.0)

    public var center: Point01 {
        Point01(x: x + width * 0.5, y: y + height * 0.5)
    }

    public func clamped() -> Rect01 {
        let cx = max(0.0, min(0.98, x))
        let cy = max(0.0, min(0.98, y))
        let cw = max(0.02, min(1.0 - cx, width))
        let ch = max(0.02, min(1.0 - cy, height))
        return Rect01(x: cx, y: cy, width: cw, height: ch)
    }
}

public struct SpringConfig: Codable, Equatable, Hashable, Sendable {
    public var stiffness: Double
    public var damping: Double
    public var mass: Double

    public init(stiffness: Double = 170.0, damping: Double = 50.0, mass: Double = 3.0) {
        self.stiffness = stiffness
        self.damping = damping
        self.mass = mass
    }

    // Spring Presets:
    // - Smooth Camera (`de`): `{ stiffness: 170, damping: 50, mass: 3.0 }` -> ζ ≈ 1.11 (Overdamped, zero bounce!)
    // - Focused Camera (`Q`): `{ stiffness: 250, damping: 40, mass: 2.25 }` -> ζ ≈ 0.84 with clamp: true
    // - Smooth Cursor (`fe`): `{ stiffness: 470, damping: 70, mass: 3.0 }` -> ζ ≈ 0.93
    // - Medium Cursor (`Q`):  `{ stiffness: 340, damping: 60, mass: 3.0 }` -> ζ ≈ 0.94
    // - Rapid Cursor (`pe`):  `{ stiffness: 530, damping: 40, mass: 1.0 }` -> ζ ≈ 0.87
    public static let defaultCursor = SpringConfig(stiffness: 470.0, damping: 70.0, mass: 3.0)
    public static let defaultCamera = SpringConfig(stiffness: 170.0, damping: 50.0, mass: 3.0)
    public static let focusedCamera = SpringConfig(stiffness: 250.0, damping: 40.0, mass: 2.25)
    public static let smoothCamera = SpringConfig(stiffness: 170.0, damping: 50.0, mass: 3.0)
}

// MARK: - Canvas & Aspect Ratio

public enum AspectRatioMode: String, Codable, CaseIterable, Sendable {
    case auto = "auto"
    case preset = "preset"
    case custom = "custom"
}

public enum AspectRatioPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case widescreen16x9 = "16:9"
    case square1x1 = "1:1"
    case classic4x3 = "4:3"
    case vertical9x16 = "9:16"
    case tall3x4 = "3:4"
    case portrait4x5 = "4:5"
    case mac16x10 = "16:10"

    public var id: String { rawValue }

    public var titleName: String {
        switch self {
        case .widescreen16x9: return "Wide"
        case .square1x1: return "Square"
        case .classic4x3: return "Classic"
        case .vertical9x16: return "Vertical"
        case .tall3x4: return "Tall"
        case .portrait4x5: return "Portrait"
        case .mac16x10: return "Display"
        }
    }

    public var ratioString: String {
        rawValue
    }

    public var label: String {
        "\(titleName) \(ratioString)"
    }

    public var ratio: Double {
        switch self {
        case .widescreen16x9: return 16.0 / 9.0
        case .square1x1: return 1.0
        case .classic4x3: return 4.0 / 3.0
        case .vertical9x16: return 9.0 / 16.0
        case .tall3x4: return 3.0 / 4.0
        case .portrait4x5: return 4.0 / 5.0
        case .mac16x10: return 16.0 / 10.0
        }
    }

    /// Proportional icon dimensions `(width, height)` inside a 16x16 icon frame aspect ratio icons!).
    public var iconSize: CGSize {
        switch self {
        case .widescreen16x9, .mac16x10: return CGSize(width: 14, height: 8)
        case .square1x1: return CGSize(width: 12, height: 12)
        case .classic4x3: return CGSize(width: 13, height: 10)
        case .vertical9x16: return CGSize(width: 8, height: 14)
        case .tall3x4: return CGSize(width: 10, height: 13)
        case .portrait4x5: return CGSize(width: 10, height: 12)
        }
    }
}

public struct CustomAspectRatio: Codable, Equatable, Hashable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double = 16, height: Double = 9) {
        self.width = width
        self.height = height
    }
}

public struct CanvasConfig: Codable, Equatable, Hashable, Sendable {
    public var aspectRatioMode: AspectRatioMode
    public var aspectRatioPreset: AspectRatioPreset
    public var customAspectRatio: CustomAspectRatio
    public var paddingRatio: Double
    public var cropRect01: Rect01

    public init(
        aspectRatioMode: AspectRatioMode = .preset,
        aspectRatioPreset: AspectRatioPreset = .widescreen16x9,
        customAspectRatio: CustomAspectRatio = CustomAspectRatio(),
        paddingRatio: Double = 0.10,
        cropRect01: Rect01 = .full
    ) {
        self.aspectRatioMode = aspectRatioMode
        self.aspectRatioPreset = aspectRatioPreset
        self.customAspectRatio = customAspectRatio
        self.paddingRatio = paddingRatio
        self.cropRect01 = cropRect01
    }

    public func effectiveAspectRatio(sourceWidth: Double, sourceHeight: Double) -> Double {
        switch aspectRatioMode {
        case .auto:
            let w = max(1.0, sourceWidth * cropRect01.width)
            let h = max(1.0, sourceHeight * cropRect01.height)
            return w / h
        case .preset:
            return aspectRatioPreset.ratio
        case .custom:
            return max(0.1, customAspectRatio.width) / max(0.1, customAspectRatio.height)
        }
    }
}

// MARK: - Background Config

public enum BackgroundType: String, Codable, CaseIterable, Identifiable, Sendable {
    case mesh = "mesh"
    case wallpaper = "wallpaper"
    case gradient = "gradient"
    case solid = "solid"
    case image = "image"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .mesh: return "Mesh"
        case .wallpaper: return "macOS"
        case .gradient: return "Gradient"
        case .solid: return "Color"
        case .image: return "Custom"
        }
    }
}

public enum GradientType: String, Codable, CaseIterable, Sendable {
    case linear = "linear"
    case radial = "radial"
}

public struct GradientStopConfig: Codable, Equatable, Hashable, Sendable {
    public var color: String
    public var location: Double

    public init(color: String, location: Double) {
        self.color = color
        self.location = location
    }
}

public struct GradientConfig: Codable, Equatable, Hashable, Sendable {
    public var type: GradientType
    public var start01: Point01
    public var end01: Point01
    public var stops: [GradientStopConfig]

    public init(
        type: GradientType = .linear,
        start01: Point01 = .zero,
        end01: Point01 = .one,
        stops: [GradientStopConfig] = [
            GradientStopConfig(color: "#4776E6", location: 0.0),
            GradientStopConfig(color: "#8E54E9", location: 1.0)
        ]
    ) {
        self.type = type
        self.start01 = start01
        self.end01 = end01
        self.stops = stops
    }
}

public struct BackgroundConfig: Codable, Equatable, Hashable, Sendable {
    public var type: BackgroundType
    public var solidColor: String
    public var gradient: GradientConfig
    public var meshPresetId: String?
    public var wallpaperRelativePath: String?
    public var systemWallpaperName: String?
    public var blurRadius: Double
    public var noiseIntensity: Double

    public init(
        type: BackgroundType = .mesh,
        solidColor: String = "#1E1E2E",
        gradient: GradientConfig = GradientConfig(),
        meshPresetId: String? = "spring-aurora",
        wallpaperRelativePath: String? = nil,
        systemWallpaperName: String? = nil,
        blurRadius: Double = 0.0,
        noiseIntensity: Double = 0.02
    ) {
        self.type = type
        self.solidColor = solidColor
        self.gradient = gradient
        self.meshPresetId = meshPresetId
        self.wallpaperRelativePath = wallpaperRelativePath
        self.systemWallpaperName = systemWallpaperName
        self.blurRadius = blurRadius
        self.noiseIntensity = noiseIntensity
    }
}

// MARK: - Frame Style (Corners, Inset, Shadow, Device Mockup)

public struct FrameInsetConfig: Codable, Equatable, Hashable, Sendable {
    public var enabled: Bool
    public var size: Double
    public var color: String
    public var opacity: Double

    public init(enabled: Bool = true, size: Double = 1.5, color: String = "#FFFFFF", opacity: Double = 0.18) {
        self.enabled = enabled
        self.size = size
        self.color = color
        self.opacity = opacity
    }
}

public struct FrameShadowConfig: Codable, Equatable, Hashable, Sendable {
    public var enabled: Bool
    public var intensity: Double
    public var blur: Double
    public var distance: Double
    public var angleDegrees: Double

    public init(
        enabled: Bool = true,
        intensity: Double = 0.42,
        blur: Double = 36.0,
        distance: Double = 22.0,
        angleDegrees: Double = 90.0
    ) {
        self.enabled = enabled
        self.intensity = intensity
        self.blur = blur
        self.distance = distance
        self.angleDegrees = angleDegrees
    }
}

public struct DeviceMockupConfig: Codable, Equatable, Hashable, Sendable {
    public var enabled: Bool
    public var deviceId: String?

    public init(enabled: Bool = false, deviceId: String? = nil) {
        self.enabled = enabled
        self.deviceId = deviceId
    }
}

public struct FrameStyleConfig: Codable, Equatable, Hashable, Sendable {
    public var borderRadius: Double
    public var inset: FrameInsetConfig
    public var shadow: FrameShadowConfig
    public var deviceMockup: DeviceMockupConfig

    public init(
        borderRadius: Double = 16.0,
        inset: FrameInsetConfig = FrameInsetConfig(),
        shadow: FrameShadowConfig = FrameShadowConfig(),
        deviceMockup: DeviceMockupConfig = DeviceMockupConfig()
    ) {
        self.borderRadius = borderRadius
        self.inset = inset
        self.shadow = shadow
        self.deviceMockup = deviceMockup
    }
}

// MARK: - Cursor Config

public enum ClickEffectStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case none = "none"
    case ripple = "ripple"
    case pulse = "pulse"
    case ring = "ring"

    public var id: String { rawValue }
}

public struct ClickEffectConfig: Codable, Equatable, Hashable, Sendable {
    public var visualStyle: ClickEffectStyle
    public var color: String
    public var soundSet: String?
    public var soundVolume: Double

    public init(
        visualStyle: ClickEffectStyle = .ripple,
        color: String = "#FFFFFF",
        soundSet: String? = "magic-mouse",
        soundVolume: Double = 0.25
    ) {
        self.visualStyle = visualStyle
        self.color = color
        self.soundSet = soundSet
        self.soundVolume = soundVolume
    }
}

public struct CursorConfig: Codable, Equatable, Hashable, Sendable {
    public var hidden: Bool
    public var scale: Double
    public var themeId: String
    public var smoothMovementEnabled: Bool
    public var spring: SpringConfig
    public var removeShakeThresholdPx: Double
    public var velocityRotationEnabled: Bool
    public var velocityRotationIntensity: Double
    public var hideWhenIdleAfterMs: Double?
    public var loopBackToStartMs: Double?
    public var clickEffect: ClickEffectConfig

    public init(
        hidden: Bool = false,
        scale: Double = 1.6,
        themeId: String = "macos-tahoe",
        smoothMovementEnabled: Bool = true,
        spring: SpringConfig = .defaultCursor,
        removeShakeThresholdPx: Double = 4.0,
        velocityRotationEnabled: Bool = true,
        velocityRotationIntensity: Double = 0.5,
        hideWhenIdleAfterMs: Double? = 3000.0,
        loopBackToStartMs: Double? = nil,
        clickEffect: ClickEffectConfig = ClickEffectConfig()
    ) {
        self.hidden = hidden
        self.scale = scale
        self.themeId = themeId
        self.smoothMovementEnabled = smoothMovementEnabled
        self.spring = spring
        self.removeShakeThresholdPx = removeShakeThresholdPx
        self.velocityRotationEnabled = velocityRotationEnabled
        self.velocityRotationIntensity = velocityRotationIntensity
        self.hideWhenIdleAfterMs = hideWhenIdleAfterMs
        self.loopBackToStartMs = loopBackToStartMs
        self.clickEffect = clickEffect
    }
}

// MARK: - Camera / Webcam Config

public enum CameraLayoutMode: String, Codable, CaseIterable, Sendable {
    case overlay = "overlay"
    case splitScreen = "split-screen"
    case cutout = "cutout"
}

public enum CameraShape: String, Codable, CaseIterable, Sendable {
    case circle = "circle"
    case squircle = "squircle"
    case rectangle = "rectangle"
}

public struct CameraConfig: Codable, Equatable, Hashable, Sendable {
    public var enabled: Bool
    public var layoutMode: CameraLayoutMode
    public var mirror: Bool
    public var position01: Point01
    public var sizeRatio: Double
    public var scaleWhenZoomed: Double
    public var shape: CameraShape
    public var borderRadiusRatio: Double
    public var shadowIntensity: Double
    public var backgroundBlur: Double
    public var aiPersonCutout: Bool

    public init(
        enabled: Bool = false,
        layoutMode: CameraLayoutMode = .overlay,
        mirror: Bool = true,
        position01: Point01 = Point01(x: 0.90, y: 0.86),
        sizeRatio: Double = 0.22,
        scaleWhenZoomed: Double = 0.80,
        shape: CameraShape = .squircle,
        borderRadiusRatio: Double = 0.22,
        shadowIntensity: Double = 0.35,
        backgroundBlur: Double = 0.0,
        aiPersonCutout: Bool = false
    ) {
        self.enabled = enabled
        self.layoutMode = layoutMode
        self.mirror = mirror
        self.position01 = position01
        self.sizeRatio = sizeRatio
        self.scaleWhenZoomed = scaleWhenZoomed
        self.shape = shape
        self.borderRadiusRatio = borderRadiusRatio
        self.shadowIntensity = shadowIntensity
        self.backgroundBlur = backgroundBlur
        self.aiPersonCutout = aiPersonCutout
    }
}

// MARK: - Motion, Audio & Captions Config

public struct MotionConfig: Codable, Equatable, Hashable, Sendable {
    public var cameraSpring: SpringConfig
    public var motionBlurIntensity: Double
    public var avoidEmptyBoundsWhenZooming: Bool

    public init(
        cameraSpring: SpringConfig = .defaultCamera,
        motionBlurIntensity: Double = 0.5,
        avoidEmptyBoundsWhenZooming: Bool = true
    ) {
        self.cameraSpring = cameraSpring
        self.motionBlurIntensity = motionBlurIntensity
        self.avoidEmptyBoundsWhenZooming = avoidEmptyBoundsWhenZooming
    }
}

public struct BackgroundMusicConfig: Codable, Equatable, Hashable, Sendable {
    public var relativePath: String?
    public var volume: Double
    public var duckDuringSpeech: Bool

    public init(relativePath: String? = nil, volume: Double = 0.08, duckDuringSpeech: Bool = true) {
        self.relativePath = relativePath
        self.volume = volume
        self.duckDuringSpeech = duckDuringSpeech
    }
}

public struct AudioConfig: Codable, Equatable, Hashable, Sendable {
    public var masterVolume: Double
    public var microphoneVolume: Double
    public var muteMicrophone: Bool
    public var voiceEnhancement: Bool
    public var systemAudioVolume: Double
    public var muteSystemAudio: Bool
    public var backgroundMusic: BackgroundMusicConfig

    public init(
        masterVolume: Double = 1.0,
        microphoneVolume: Double = 1.0,
        muteMicrophone: Bool = false,
        voiceEnhancement: Bool = true,
        systemAudioVolume: Double = 1.0,
        muteSystemAudio: Bool = false,
        backgroundMusic: BackgroundMusicConfig = BackgroundMusicConfig()
    ) {
        self.masterVolume = masterVolume
        self.microphoneVolume = microphoneVolume
        self.muteMicrophone = muteMicrophone
        self.voiceEnhancement = voiceEnhancement
        self.systemAudioVolume = systemAudioVolume
        self.muteSystemAudio = muteSystemAudio
        self.backgroundMusic = backgroundMusic
    }
}

public struct CaptionSegment: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var sourceStartMs: Double
    public var sourceEndMs: Double
    public var text: String

    public init(id: String = UUID().uuidString, sourceStartMs: Double, sourceEndMs: Double, text: String) {
        self.id = id
        self.sourceStartMs = sourceStartMs
        self.sourceEndMs = sourceEndMs
        self.text = text
    }
}

public struct CaptionsConfig: Codable, Equatable, Hashable, Sendable {
    public var enabled: Bool
    public var showKeystrokes: Bool
    public var keystrokesPosition01: Point01
    public var fontFamily: String
    public var fontSizeRatio: Double
    public var textColor: String
    public var backgroundColor: String
    public var position01: Point01
    public var animationStyle: String
    public var segments: [CaptionSegment]

    public init(
        enabled: Bool = false,
        showKeystrokes: Bool = true,
        keystrokesPosition01: Point01 = Point01(x: 0.5, y: 0.90),
        fontFamily: String = "SF Pro Rounded",
        fontSizeRatio: Double = 0.045,
        textColor: String = "#FFFFFF",
        backgroundColor: String = "#000000CC",
        position01: Point01 = Point01(x: 0.5, y: 0.88),
        animationStyle: String = "word-by-word",
        segments: [CaptionSegment] = []
    ) {
        self.enabled = enabled
        self.showKeystrokes = showKeystrokes
        self.keystrokesPosition01 = keystrokesPosition01
        self.fontFamily = fontFamily
        self.fontSizeRatio = fontSizeRatio
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.position01 = position01
        self.animationStyle = animationStyle
        self.segments = segments
    }
}

// MARK: - NLE Timeline Models (Slices, Zooms, Multi-Track Masks)

public struct ClipSlice: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var sourceStartMs: Double
    public var sourceEndMs: Double
    public var speed: Double
    public var systemAudioVolume: Double
    public var muted: Bool
    public var hideCursor: Bool
    public var disableSmoothCursor: Bool

    public init(
        id: String = UUID().uuidString,
        sourceStartMs: Double,
        sourceEndMs: Double,
        speed: Double = 1.0,
        systemAudioVolume: Double = 1.0,
        muted: Bool = false,
        hideCursor: Bool = false,
        disableSmoothCursor: Bool = false
    ) {
        self.id = id
        self.sourceStartMs = sourceStartMs
        self.sourceEndMs = sourceEndMs
        self.speed = max(0.1, speed)
        self.systemAudioVolume = max(0.0, min(2.0, systemAudioVolume))
        self.muted = muted
        self.hideCursor = hideCursor
        self.disableSmoothCursor = disableSmoothCursor
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sourceStartMs
        case sourceEndMs
        case speed
        case systemAudioVolume
        case muted
        case hideCursor
        case disableSmoothCursor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.sourceStartMs = try container.decode(Double.self, forKey: .sourceStartMs)
        self.sourceEndMs = try container.decode(Double.self, forKey: .sourceEndMs)
        self.speed = max(0.1, try container.decodeIfPresent(Double.self, forKey: .speed) ?? 1.0)
        self.systemAudioVolume = max(0.0, min(2.0, try container.decodeIfPresent(Double.self, forKey: .systemAudioVolume) ?? 1.0))
        self.muted = try container.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        self.hideCursor = try container.decodeIfPresent(Bool.self, forKey: .hideCursor) ?? false
        self.disableSmoothCursor = try container.decodeIfPresent(Bool.self, forKey: .disableSmoothCursor) ?? false
    }

    public var sourceDurationMs: Double {
        max(0.0, sourceEndMs - sourceStartMs)
    }

    public var timelineDurationMs: Double {
        sourceDurationMs / max(0.1, speed)
    }
}

public enum ZoomMode: String, Codable, CaseIterable, Sendable {
    case followCursor = "follow-cursor"
    case manual = "manual"
}

public enum ZoomPresentation: String, Codable, CaseIterable, Sendable {
    case screen = "screen"
    case loupe = "loupe"
}

public struct LoupeConfig: Codable, Equatable, Hashable, Sendable {
    public var radius01: Double
    public var bevelRatio: Double
    public var chromaticAberration: Double

    public init(radius01: Double = 0.35, bevelRatio: Double = 0.2, chromaticAberration: Double = 0.5) {
        self.radius01 = radius01
        self.bevelRatio = bevelRatio
        self.chromaticAberration = chromaticAberration
    }
}

public struct ZoomBlock: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var sourceStartMs: Double
    public var sourceEndMs: Double
    public var scale: Double
    public var mode: ZoomMode
    public var presentation: ZoomPresentation
    public var manualCenter01: Point01
    public var loupe: LoupeConfig
    public var disabled: Bool

    public init(
        id: String = UUID().uuidString,
        sourceStartMs: Double,
        sourceEndMs: Double,
        scale: Double = 1.8,
        mode: ZoomMode = .followCursor,
        presentation: ZoomPresentation = .screen,
        manualCenter01: Point01 = .center,
        loupe: LoupeConfig = LoupeConfig(),
        disabled: Bool = false
    ) {
        self.id = id
        self.sourceStartMs = sourceStartMs
        self.sourceEndMs = sourceEndMs
        self.scale = scale
        self.mode = mode
        self.presentation = presentation
        self.manualCenter01 = manualCenter01
        self.loupe = loupe
        self.disabled = disabled
    }
}

public enum MaskType: String, Codable, CaseIterable, Identifiable, Sendable {
    case blur = "blur"
    case spotlight = "spotlight"

    public var id: String { rawValue }
}

public enum MaskStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case gaussian = "gaussian"
    case pixelate = "pixelate"
    case solid = "solid"
    case dim = "dim"

    public var id: String { rawValue }
}

public struct MaskKeyframe: Codable, Equatable, Hashable, Sendable {
    public var sourceMs: Double
    public var rect01: Rect01

    public init(sourceMs: Double, rect01: Rect01) {
        self.sourceMs = sourceMs
        self.rect01 = rect01
    }
}

public struct MaskItem: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var sourceStartMs: Double
    public var sourceEndMs: Double
    public var type: MaskType
    public var style: MaskStyle
    public var intensity: Double
    public var cornerRadius: Double
    public var keyframes: [MaskKeyframe]
    public var disabled: Bool

    public init(
        id: String = UUID().uuidString,
        sourceStartMs: Double,
        sourceEndMs: Double,
        type: MaskType = .blur,
        style: MaskStyle = .gaussian,
        intensity: Double = 36.0,
        cornerRadius: Double = 10.0,
        keyframes: [MaskKeyframe],
        disabled: Bool = false
    ) {
        self.id = id
        self.sourceStartMs = sourceStartMs
        self.sourceEndMs = sourceEndMs
        self.type = type
        self.style = style
        self.intensity = intensity
        self.cornerRadius = cornerRadius
        self.keyframes = keyframes
        self.disabled = disabled
    }

    /// Interpolates the mask rectangle at the given `sourceMs` across keyframes.
    public func interpolatedRect(at sourceMs: Double) -> Rect01 {
        guard !keyframes.isEmpty else {
            return Rect01(x: 0.25, y: 0.25, width: 0.4, height: 0.15)
        }
        let sorted = keyframes.sorted { $0.sourceMs < $1.sourceMs }
        if sorted.count == 1 || sourceMs <= sorted.first!.sourceMs {
            return sorted.first!.rect01
        }
        if sourceMs >= sorted.last!.sourceMs {
            return sorted.last!.rect01
        }
        for i in 0..<(sorted.count - 1) {
            let k0 = sorted[i]
            let k1 = sorted[i + 1]
            if sourceMs >= k0.sourceMs && sourceMs <= k1.sourceMs {
                let span = max(0.001, k1.sourceMs - k0.sourceMs)
                let t = (sourceMs - k0.sourceMs) / span
                return Rect01(
                    x: k0.rect01.x + (k1.rect01.x - k0.rect01.x) * t,
                    y: k0.rect01.y + (k1.rect01.y - k0.rect01.y) * t,
                    width: k0.rect01.width + (k1.rect01.width - k0.rect01.width) * t,
                    height: k0.rect01.height + (k1.rect01.height - k0.rect01.height) * t
                )
            }
        }
        return sorted.last!.rect01
    }

    public mutating func setRect(_ rect: Rect01, at sourceMs: Double) {
        let clamped = rect.clamped()
        if keyframes.isEmpty {
            keyframes = [MaskKeyframe(sourceMs: sourceStartMs, rect01: clamped)]
            return
        }
        if keyframes.count == 1 {
            keyframes[0].rect01 = clamped
            return
        }
        if let idx = keyframes.firstIndex(where: { abs($0.sourceMs - sourceMs) < 120.0 }) {
            keyframes[idx].rect01 = clamped
        } else {
            keyframes.append(MaskKeyframe(sourceMs: sourceMs, rect01: clamped))
            keyframes.sort { $0.sourceMs < $1.sourceMs }
        }
    }
}

public struct MaskTrack: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var isHidden: Bool
    public var items: [MaskItem]

    public init(id: String = UUID().uuidString, name: String, isHidden: Bool = false, items: [MaskItem] = []) {
        self.id = id
        self.name = name
        self.isHidden = isHidden
        self.items = items
    }

    enum CodingKeys: String, CodingKey {
        case id, name, isHidden, items
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        self.items = try container.decodeIfPresent([MaskItem].self, forKey: .items) ?? []
    }
}

public struct TimelineConfig: Codable, Equatable, Hashable, Sendable {
    public var slices: [ClipSlice]
    public var zooms: [ZoomBlock]
    public var isZoomTrackHidden: Bool
    public var maskTracks: [MaskTrack]

    public init(
        slices: [ClipSlice] = [],
        zooms: [ZoomBlock] = [],
        isZoomTrackHidden: Bool = false,
        maskTracks: [MaskTrack] = []
    ) {
        self.slices = slices
        self.zooms = zooms
        self.isZoomTrackHidden = isZoomTrackHidden
        self.maskTracks = maskTracks
    }

    enum CodingKeys: String, CodingKey {
        case slices, zooms, isZoomTrackHidden, maskTracks
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.slices = try container.decodeIfPresent([ClipSlice].self, forKey: .slices) ?? []
        self.zooms = try container.decodeIfPresent([ZoomBlock].self, forKey: .zooms) ?? []
        self.isZoomTrackHidden = try container.decodeIfPresent(Bool.self, forKey: .isZoomTrackHidden) ?? false
        self.maskTracks = try container.decodeIfPresent([MaskTrack].self, forKey: .maskTracks) ?? []
    }
}

// MARK: - Root ProjectDocument (`project.json`)

public struct ProjectDocument: Codable, Equatable, Hashable, Sendable {
    public var schemaVersion: String
    public var id: String
    public var name: String
    public var createdAt: String
    public var updatedAt: String
    public var canvas: CanvasConfig
    public var background: BackgroundConfig
    public var frameStyle: FrameStyleConfig
    public var cursor: CursorConfig
    public var camera: CameraConfig
    public var motion: MotionConfig
    public var audio: AudioConfig
    public var captions: CaptionsConfig
    public var timeline: TimelineConfig

    public init(
        schemaVersion: String = "1.0.0",
        id: String = UUID().uuidString,
        name: String = "Untitled Recording",
        createdAt: String = ISO8601DateFormatter().string(from: Date()),
        updatedAt: String = ISO8601DateFormatter().string(from: Date()),
        canvas: CanvasConfig = CanvasConfig(),
        background: BackgroundConfig = BackgroundConfig(),
        frameStyle: FrameStyleConfig = FrameStyleConfig(),
        cursor: CursorConfig = CursorConfig(),
        camera: CameraConfig = CameraConfig(),
        motion: MotionConfig = MotionConfig(),
        audio: AudioConfig = AudioConfig(),
        captions: CaptionsConfig = CaptionsConfig(),
        timeline: TimelineConfig = TimelineConfig()
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.canvas = canvas
        self.background = background
        self.frameStyle = frameStyle
        self.cursor = cursor
        self.camera = camera
        self.motion = motion
        self.audio = audio
        self.captions = captions
        self.timeline = timeline
    }
}
