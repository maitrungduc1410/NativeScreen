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
    // - Smooth Camera: `{ stiffness: 170, damping: 50, mass: 3.0 }` -> ζ ≈ 1.11 (Overdamped, zero bounce!)
    // - Focused Camera: `{ stiffness: 250, damping: 40, mass: 2.25 }` -> ζ ≈ 0.84 with clamp: true
    // - Smooth Cursor: `{ stiffness: 470, damping: 70, mass: 3.0 }` -> ζ ≈ 0.93
    // - Medium Cursor:  `{ stiffness: 340, damping: 60, mass: 3.0 }` -> ζ ≈ 0.94
    // - Rapid Cursor:  `{ stiffness: 530, damping: 40, mass: 1.0 }` -> ζ ≈ 0.87
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
        case .widescreen16x9: return String(localized: "Wide")
        case .square1x1: return String(localized: "Square")
        case .classic4x3: return String(localized: "Classic")
        case .vertical9x16: return String(localized: "Vertical")
        case .tall3x4: return String(localized: "Tall")
        case .portrait4x5: return String(localized: "Portrait")
        case .mac16x10: return String(localized: "Display")
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
            let shortest = min(w, h)
            let pad = shortest * max(0.0, paddingRatio)
            return (w + 2.0 * pad) / (h + 2.0 * pad)
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
        case .mesh: return String(localized: "Mesh")
        case .wallpaper: return String(localized: "macOS")
        case .gradient: return String(localized: "Gradient")
        case .solid: return String(localized: "Color")
        case .image: return String(localized: "Custom")
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
    public var hideSensitiveData: Bool
    public var sensitiveDataCustomPhrases: [String]
    public var hideFaces: Bool

    public init(
        type: BackgroundType = .mesh,
        solidColor: String = "#1E1E2E",
        gradient: GradientConfig = GradientConfig(),
        meshPresetId: String? = "spring-aurora",
        wallpaperRelativePath: String? = nil,
        systemWallpaperName: String? = nil,
        blurRadius: Double = 0.0,
        noiseIntensity: Double = 0.02,
        hideSensitiveData: Bool = false,
        sensitiveDataCustomPhrases: [String] = [],
        hideFaces: Bool = false
    ) {
        self.type = type
        self.solidColor = solidColor
        self.gradient = gradient
        self.meshPresetId = meshPresetId
        self.wallpaperRelativePath = wallpaperRelativePath
        self.systemWallpaperName = systemWallpaperName
        self.blurRadius = blurRadius
        self.noiseIntensity = noiseIntensity
        self.hideSensitiveData = hideSensitiveData
        self.sensitiveDataCustomPhrases = sensitiveDataCustomPhrases
        self.hideFaces = hideFaces
    }

    enum CodingKeys: String, CodingKey {
        case type, solidColor, gradient, meshPresetId, wallpaperRelativePath, systemWallpaperName
        case blurRadius, noiseIntensity, hideSensitiveData, sensitiveDataCustomPhrases, hideFaces
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decodeIfPresent(BackgroundType.self, forKey: .type) ?? .mesh
        self.solidColor = try container.decodeIfPresent(String.self, forKey: .solidColor) ?? "#1E1E2E"
        self.gradient = try container.decodeIfPresent(GradientConfig.self, forKey: .gradient) ?? GradientConfig()
        self.meshPresetId = try container.decodeIfPresent(String.self, forKey: .meshPresetId)
        self.wallpaperRelativePath = try container.decodeIfPresent(String.self, forKey: .wallpaperRelativePath)
        self.systemWallpaperName = try container.decodeIfPresent(String.self, forKey: .systemWallpaperName)
        self.blurRadius = try container.decodeIfPresent(Double.self, forKey: .blurRadius) ?? 0.0
        self.noiseIntensity = try container.decodeIfPresent(Double.self, forKey: .noiseIntensity) ?? 0.02
        self.hideSensitiveData = try container.decodeIfPresent(Bool.self, forKey: .hideSensitiveData) ?? false
        self.sensitiveDataCustomPhrases = try container.decodeIfPresent([String].self, forKey: .sensitiveDataCustomPhrases) ?? []
        self.hideFaces = try container.decodeIfPresent(Bool.self, forKey: .hideFaces) ?? false
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
    public var isDirectional: Bool
    public var intensity: Double
    public var blur: Double
    public var distance: Double
    public var angleDegrees: Double

    public init(
        enabled: Bool = true,
        isDirectional: Bool = true,
        intensity: Double = 0.42,
        blur: Double = 36.0,
        distance: Double = 22.0,
        angleDegrees: Double = 90.0
    ) {
        self.enabled = enabled
        self.isDirectional = isDirectional
        self.intensity = intensity
        self.blur = blur
        self.distance = distance
        self.angleDegrees = angleDegrees
    }

    enum CodingKeys: String, CodingKey {
        case enabled, isDirectional, intensity, blur, distance, angleDegrees
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.isDirectional = try container.decodeIfPresent(Bool.self, forKey: .isDirectional) ?? true
        self.intensity = try container.decodeIfPresent(Double.self, forKey: .intensity) ?? 0.42
        self.blur = try container.decodeIfPresent(Double.self, forKey: .blur) ?? 36.0
        self.distance = try container.decodeIfPresent(Double.self, forKey: .distance) ?? 22.0
        self.angleDegrees = try container.decodeIfPresent(Double.self, forKey: .angleDegrees) ?? 90.0
    }
}

public enum DeviceFrameMatchMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case perfect = "perfect"
    case flexible = "flexible"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .perfect: return "Perfect"
        case .flexible: return "Flexible"
        }
    }

    public var iconName: String {
        switch self {
        case .perfect: return "iphone"
        case .flexible: return "iphone.sizes"
        }
    }

    public var descriptionText: String {
        switch self {
        case .perfect:
            return "Show only device frames that precisely match your recording size."
        case .flexible:
            return "Show all device frames, even those that don't precisely match your recording size."
        }
    }
}

public struct DeviceMockupConfig: Codable, Equatable, Hashable, Sendable {
    public var enabled: Bool
    public var deviceId: String?
    public var matchMode: DeviceFrameMatchMode
    public var colorVariantId: String

    public init(
        enabled: Bool = false,
        deviceId: String? = "macbook-pro-16",
        matchMode: DeviceFrameMatchMode = .flexible,
        colorVariantId: String = "space-black"
    ) {
        self.enabled = enabled
        self.deviceId = deviceId
        self.matchMode = matchMode
        self.colorVariantId = colorVariantId
    }

    enum CodingKeys: String, CodingKey {
        case enabled, deviceId, matchMode, colorVariantId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.deviceId = try container.decodeIfPresent(String.self, forKey: .deviceId) ?? "macbook-pro-16"
        self.matchMode = try container.decodeIfPresent(DeviceFrameMatchMode.self, forKey: .matchMode) ?? .flexible
        self.colorVariantId = try container.decodeIfPresent(String.self, forKey: .colorVariantId) ?? "space-black"
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
    case circle = "circle"
    case ripple = "ripple"
    case pulse = "pulse"
    case ring = "ring"

    public var id: String { rawValue }
}

public enum CursorRotationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case tilt = "velocity"
    case follow = "directional"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .tilt: return String(localized: "Tilt")
        case .follow: return String(localized: "Follow")
        }
    }

    public var descriptionText: String {
        switch self {
        case .tilt:
            return String(localized: "Leans with fast horizontal movement, settling back upright at rest.")
        case .follow:
            return String(localized: "Points along the direction of travel, like pulled on a leash - and keeps its bearing at rest.")
        }
    }
}

public struct ClickEffectConfig: Codable, Equatable, Hashable, Sendable {
    public var visualStyle: ClickEffectStyle
    public var color: String
    public var soundSet: String?
    public var soundVolume: Double

    public init(
        visualStyle: ClickEffectStyle = .none,
        color: String = "#FFFFFF",
        soundSet: String? = nil,
        soundVolume: Double = 0.50
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
    public var variantId: String?
    public var alwaysUsePointer: Bool
    public var smoothMovementEnabled: Bool
    public var spring: SpringConfig
    public var baseRotationDegrees: Double
    public var rotationMode: CursorRotationMode
    public var velocityRotationEnabled: Bool
    public var velocityRotationIntensity: Double
    public var hideWhenIdleAfterMs: Double?
    public var loopBackToStartMs: Double?
    public var stopMovementInLastPartMs: Double
    public var removeShakeThresholdPx: Double
    public var optimizeCursorChanges: Bool
    public var keepInSyncWithHovers: Bool
    public var clickEffect: ClickEffectConfig

    public init(
        hidden: Bool = false,
        scale: Double = 1.6,
        themeId: String = CursorThemePreset.defaultThemeId,
        variantId: String? = nil,
        alwaysUsePointer: Bool = false,
        smoothMovementEnabled: Bool = true,
        spring: SpringConfig = .defaultCursor,
        baseRotationDegrees: Double = 0.0,
        rotationMode: CursorRotationMode = .tilt,
        velocityRotationEnabled: Bool = true,
        velocityRotationIntensity: Double = 0.5,
        hideWhenIdleAfterMs: Double? = nil,
        loopBackToStartMs: Double? = nil,
        stopMovementInLastPartMs: Double = 0.0,
        removeShakeThresholdPx: Double = 4.0,
        optimizeCursorChanges: Bool = true,
        keepInSyncWithHovers: Bool = true,
        clickEffect: ClickEffectConfig = ClickEffectConfig()
    ) {
        self.hidden = hidden
        self.scale = scale
        self.themeId = themeId
        self.variantId = variantId
        self.alwaysUsePointer = alwaysUsePointer
        self.smoothMovementEnabled = smoothMovementEnabled
        self.spring = spring
        self.baseRotationDegrees = baseRotationDegrees
        self.rotationMode = rotationMode
        self.velocityRotationEnabled = velocityRotationEnabled
        self.velocityRotationIntensity = velocityRotationIntensity
        self.hideWhenIdleAfterMs = hideWhenIdleAfterMs
        self.loopBackToStartMs = loopBackToStartMs
        self.stopMovementInLastPartMs = stopMovementInLastPartMs
        self.removeShakeThresholdPx = removeShakeThresholdPx
        self.optimizeCursorChanges = optimizeCursorChanges
        self.keepInSyncWithHovers = keepInSyncWithHovers
        self.clickEffect = clickEffect
    }

    private enum CodingKeys: String, CodingKey {
        case hidden
        case scale
        case themeId
        case variantId
        case alwaysUsePointer
        case smoothMovementEnabled
        case spring
        case baseRotationDegrees
        case rotationMode
        case velocityRotationEnabled
        case velocityRotationIntensity
        case hideWhenIdleAfterMs
        case loopBackToStartMs
        case stopMovementInLastPartMs
        case removeShakeThresholdPx
        case optimizeCursorChanges
        case keepInSyncWithHovers
        case clickEffect
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        self.scale = try container.decodeIfPresent(Double.self, forKey: .scale) ?? 1.6
        let theme = CursorThemePreset.migrateLegacyTheme(
            themeId: try container.decodeIfPresent(String.self, forKey: .themeId) ?? CursorThemePreset.defaultThemeId,
            variantId: try container.decodeIfPresent(String.self, forKey: .variantId)
        )
        self.themeId = theme.themeId
        self.variantId = theme.variantId
        self.alwaysUsePointer = try container.decodeIfPresent(Bool.self, forKey: .alwaysUsePointer) ?? false
        self.smoothMovementEnabled = try container.decodeIfPresent(Bool.self, forKey: .smoothMovementEnabled) ?? true
        self.spring = try container.decodeIfPresent(SpringConfig.self, forKey: .spring) ?? .defaultCursor
        self.baseRotationDegrees = try container.decodeIfPresent(Double.self, forKey: .baseRotationDegrees) ?? 0.0
        self.rotationMode = try container.decodeIfPresent(CursorRotationMode.self, forKey: .rotationMode) ?? .tilt
        self.velocityRotationEnabled = try container.decodeIfPresent(Bool.self, forKey: .velocityRotationEnabled) ?? true
        self.velocityRotationIntensity = try container.decodeIfPresent(Double.self, forKey: .velocityRotationIntensity) ?? 0.5
        self.hideWhenIdleAfterMs = try container.decodeIfPresent(Double.self, forKey: .hideWhenIdleAfterMs)
        self.loopBackToStartMs = try container.decodeIfPresent(Double.self, forKey: .loopBackToStartMs)
        self.stopMovementInLastPartMs = try container.decodeIfPresent(Double.self, forKey: .stopMovementInLastPartMs) ?? 0.0
        self.removeShakeThresholdPx = try container.decodeIfPresent(Double.self, forKey: .removeShakeThresholdPx) ?? 4.0
        self.optimizeCursorChanges = try container.decodeIfPresent(Bool.self, forKey: .optimizeCursorChanges) ?? true
        self.keepInSyncWithHovers = try container.decodeIfPresent(Bool.self, forKey: .keepInSyncWithHovers) ?? true
        self.clickEffect = try container.decodeIfPresent(ClickEffectConfig.self, forKey: .clickEffect) ?? ClickEffectConfig()
    }
}

// MARK: - Camera / Webcam Config

public enum CameraLayoutMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case overlay = "overlay"
    case splitScreen = "split-screen"
    case cutout = "cutout"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .overlay: return "Camera overlay"
        case .splitScreen: return "Split screen"
        case .cutout: return "Camera cutout"
        }
    }
}

public enum CameraAspectRatioPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case widescreen16x9 = "16:9"
    case classic4x3 = "4:3"
    case square1x1 = "1:1"
    case portrait3x4 = "3:4"
    case vertical9x16 = "9:16"

    public var id: String { rawValue }

    public var aspectValue: Double {
        switch self {
        case .widescreen16x9: return 16.0 / 9.0
        case .classic4x3: return 4.0 / 3.0
        case .square1x1: return 1.0
        case .portrait3x4: return 3.0 / 4.0
        case .vertical9x16: return 9.0 / 16.0
        }
    }
}

public enum CameraColorGradePreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case original = "Original"
    case studio = "Studio"
    case cinema = "Cinema"
    case film = "Film"
    case golden = "Golden"
    case cream = "Cream"
    case terra = "Terra"
    case moody = "Moody"
    case arctic = "Arctic"
    case neon = "Neon"
    case punch = "Punch"
    case fade = "Fade"
    case mono = "Mono"

    public var id: String { rawValue }

    public var descriptionText: String {
        switch self {
        case .original: return String(localized: "Original ungraded camera feed")
        case .studio: return String(localized: "Evened-out skin, gentle filmic contrast, warm-vs-cool separation")
        case .cinema: return String(localized: "Shadows dive into teal while skin stays warm and full")
        case .film: return String(localized: "35mm print emulation with creamy shoulder and warm mids")
        case .golden: return String(localized: "Golden-hour amber warmth with honeyed highlights")
        case .cream: return String(localized: "Soft pastel portrait film with open shadows and milky highlights")
        case .terra: return String(localized: "Earthy terracotta warmth and muted sage greens")
        case .moody: return String(localized: "Deep atmospheric tonality with warm skin in cool shadows")
        case .arctic: return String(localized: "Bright crisp winter daylight with clean icy highlights")
        case .neon: return String(localized: "Late-night electric violet shadows with true warm skin")
        case .punch: return String(localized: "Vivid commercial contrast and disciplined color pop")
        case .fade: return String(localized: "Sun-bleached nostalgia with lifted blacks and softened highlights")
        case .mono: return String(localized: "Warm classic black & white with orange-filter skin luminance")
        }
    }
}

public enum CameraShape: String, Codable, CaseIterable, Sendable {
    case circle = "circle"
    case squircle = "squircle"
    case rectangle = "rectangle"
}

public struct CustomCameraColorPreset: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var warmth: Double
    public var backgroundPop: Double
    public var contrast: Double
    public var colorIntensity: Double

    public init(
        id: String = UUID().uuidString,
        name: String = "My preset",
        warmth: Double = 0.0,
        backgroundPop: Double = 0.20,
        contrast: Double = 0.25,
        colorIntensity: Double = 0.20
    ) {
        self.id = id
        self.name = name
        self.warmth = warmth
        self.backgroundPop = backgroundPop
        self.contrast = contrast
        self.colorIntensity = colorIntensity
    }
}

public struct CameraConfig: Codable, Equatable, Hashable, Sendable {
    public var enabled: Bool
    public var layoutMode: CameraLayoutMode
    public var aspectRatioPreset: CameraAspectRatioPreset
    public var mirror: Bool
    public var position01: Point01
    public var sizeRatio: Double
    public var makeSmallerDuringZoom: Bool
    public var scaleWhenZoomed: Double
    public var shape: CameraShape
    public var borderRadiusRatio: Double
    public var shadowIntensity: Double
    public var backgroundBlur: Double
    public var aiPersonCutout: Bool
    public var hideDuringSilenceMs: Double?
    public var splitScreenRatio01: Double
    public var splitFlip: Bool
    public var splitEnablePadding: Bool
    public var cutoutPositionX01: Double
    public var cutoutEdgeSoftness: Double
    public var cutoutEdgeInset: Double
    public var cutoutAvoidEmptyArea: Bool
    public var colorGradePreset: CameraColorGradePreset
    public var customLUTRelativePath: String?
    public var customColorPresets: [CustomCameraColorPreset]
    public var selectedCustomColorPresetID: String?
    public var colorGradeIntensity: Double
    public var sharpen01: Double
    public var cropRect01: Rect01
    public var enableFaceTracking: Bool
    public var delayAdjustmentMs: Double

    public init(
        enabled: Bool = true,
        layoutMode: CameraLayoutMode = .overlay,
        aspectRatioPreset: CameraAspectRatioPreset = .square1x1,
        mirror: Bool = false,
        position01: Point01 = Point01(x: 1.0, y: 1.0),
        sizeRatio: Double = 0.56,
        makeSmallerDuringZoom: Bool = true,
        scaleWhenZoomed: Double = 0.66,
        shape: CameraShape = .squircle,
        borderRadiusRatio: Double = 0.22,
        shadowIntensity: Double = 0.35,
        backgroundBlur: Double = 0.0,
        aiPersonCutout: Bool = false,
        hideDuringSilenceMs: Double? = nil,
        splitScreenRatio01: Double = 0.50,
        splitFlip: Bool = false,
        splitEnablePadding: Bool = false,
        cutoutPositionX01: Double = 0.0,
        cutoutEdgeSoftness: Double = 0.20,
        cutoutEdgeInset: Double = 0.0,
        cutoutAvoidEmptyArea: Bool = false,
        colorGradePreset: CameraColorGradePreset = .original,
        customLUTRelativePath: String? = nil,
        customColorPresets: [CustomCameraColorPreset] = [],
        selectedCustomColorPresetID: String? = nil,
        colorGradeIntensity: Double = 1.0,
        sharpen01: Double = 0.0,
        cropRect01: Rect01 = .full,
        enableFaceTracking: Bool = false,
        delayAdjustmentMs: Double = 0.0
    ) {
        self.enabled = enabled
        self.layoutMode = layoutMode
        self.aspectRatioPreset = aspectRatioPreset
        self.mirror = mirror
        self.position01 = position01
        self.sizeRatio = sizeRatio
        self.makeSmallerDuringZoom = makeSmallerDuringZoom
        self.scaleWhenZoomed = scaleWhenZoomed
        self.shape = shape
        self.borderRadiusRatio = borderRadiusRatio
        self.shadowIntensity = shadowIntensity
        self.backgroundBlur = backgroundBlur
        self.aiPersonCutout = aiPersonCutout
        self.hideDuringSilenceMs = hideDuringSilenceMs
        self.splitScreenRatio01 = splitScreenRatio01
        self.splitFlip = splitFlip
        self.splitEnablePadding = splitEnablePadding
        self.cutoutPositionX01 = cutoutPositionX01
        self.cutoutEdgeSoftness = cutoutEdgeSoftness
        self.cutoutEdgeInset = cutoutEdgeInset
        self.cutoutAvoidEmptyArea = cutoutAvoidEmptyArea
        self.colorGradePreset = colorGradePreset
        self.customLUTRelativePath = customLUTRelativePath
        self.customColorPresets = customColorPresets
        self.selectedCustomColorPresetID = selectedCustomColorPresetID
        self.colorGradeIntensity = colorGradeIntensity
        self.sharpen01 = sharpen01
        self.cropRect01 = cropRect01
        self.enableFaceTracking = enableFaceTracking
        self.delayAdjustmentMs = delayAdjustmentMs
    }

    enum CodingKeys: String, CodingKey {
        case enabled, layoutMode, aspectRatioPreset, mirror, position01, sizeRatio
        case makeSmallerDuringZoom, scaleWhenZoomed, shape, borderRadiusRatio
        case shadowIntensity, backgroundBlur, aiPersonCutout, hideDuringSilenceMs
        case splitScreenRatio01, splitFlip, splitEnablePadding, cutoutPositionX01
        case cutoutEdgeSoftness, cutoutEdgeInset, cutoutAvoidEmptyArea
        case colorGradePreset, customLUTRelativePath, customColorPresets, selectedCustomColorPresetID, colorGradeIntensity
        case sharpen01, cropRect01, enableFaceTracking, delayAdjustmentMs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.layoutMode = try container.decodeIfPresent(CameraLayoutMode.self, forKey: .layoutMode) ?? .overlay
        self.aspectRatioPreset = try container.decodeIfPresent(CameraAspectRatioPreset.self, forKey: .aspectRatioPreset) ?? .square1x1
        self.mirror = try container.decodeIfPresent(Bool.self, forKey: .mirror) ?? false
        self.position01 = try container.decodeIfPresent(Point01.self, forKey: .position01) ?? Point01(x: 1.0, y: 1.0)
        self.sizeRatio = try container.decodeIfPresent(Double.self, forKey: .sizeRatio) ?? 0.56
        self.makeSmallerDuringZoom = try container.decodeIfPresent(Bool.self, forKey: .makeSmallerDuringZoom) ?? true
        self.scaleWhenZoomed = try container.decodeIfPresent(Double.self, forKey: .scaleWhenZoomed) ?? 0.66
        self.shape = try container.decodeIfPresent(CameraShape.self, forKey: .shape) ?? .squircle
        self.borderRadiusRatio = try container.decodeIfPresent(Double.self, forKey: .borderRadiusRatio) ?? 0.22
        self.shadowIntensity = try container.decodeIfPresent(Double.self, forKey: .shadowIntensity) ?? 0.35
        self.backgroundBlur = try container.decodeIfPresent(Double.self, forKey: .backgroundBlur) ?? 0.0
        self.aiPersonCutout = try container.decodeIfPresent(Bool.self, forKey: .aiPersonCutout) ?? false
        self.hideDuringSilenceMs = try container.decodeIfPresent(Double.self, forKey: .hideDuringSilenceMs)
        self.splitScreenRatio01 = try container.decodeIfPresent(Double.self, forKey: .splitScreenRatio01) ?? 0.50
        self.splitFlip = try container.decodeIfPresent(Bool.self, forKey: .splitFlip) ?? false
        self.splitEnablePadding = try container.decodeIfPresent(Bool.self, forKey: .splitEnablePadding) ?? false
        self.cutoutPositionX01 = try container.decodeIfPresent(Double.self, forKey: .cutoutPositionX01) ?? 0.0
        self.cutoutEdgeSoftness = try container.decodeIfPresent(Double.self, forKey: .cutoutEdgeSoftness) ?? 0.20
        self.cutoutEdgeInset = try container.decodeIfPresent(Double.self, forKey: .cutoutEdgeInset) ?? 0.0
        self.cutoutAvoidEmptyArea = try container.decodeIfPresent(Bool.self, forKey: .cutoutAvoidEmptyArea) ?? false
        self.colorGradePreset = try container.decodeIfPresent(CameraColorGradePreset.self, forKey: .colorGradePreset) ?? .original
        self.customLUTRelativePath = try container.decodeIfPresent(String.self, forKey: .customLUTRelativePath)
        self.customColorPresets = try container.decodeIfPresent([CustomCameraColorPreset].self, forKey: .customColorPresets) ?? []
        self.selectedCustomColorPresetID = try container.decodeIfPresent(String.self, forKey: .selectedCustomColorPresetID)
        self.colorGradeIntensity = try container.decodeIfPresent(Double.self, forKey: .colorGradeIntensity) ?? 1.0
        self.sharpen01 = try container.decodeIfPresent(Double.self, forKey: .sharpen01) ?? 0.0
        self.cropRect01 = try container.decodeIfPresent(Rect01.self, forKey: .cropRect01) ?? .full
        self.enableFaceTracking = try container.decodeIfPresent(Bool.self, forKey: .enableFaceTracking) ?? false
        self.delayAdjustmentMs = try container.decodeIfPresent(Double.self, forKey: .delayAdjustmentMs) ?? 0.0
    }
}

// MARK: - Motion, Audio & Captions Config

public struct MotionConfig: Codable, Equatable, Hashable, Sendable {
    public var cameraSpring: SpringConfig
    public var motionBlurIntensity: Double
    public var avoidEmptyBoundsWhenZooming: Bool

    public init(
        cameraSpring: SpringConfig = .defaultCamera,
        motionBlurIntensity: Double = 1.0,
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
    public var muted: Bool
    public var duckDuringSpeech: Bool

    public init(relativePath: String? = nil, volume: Double = 0.08, muted: Bool = false, duckDuringSpeech: Bool = true) {
        self.relativePath = relativePath
        self.volume = volume
        self.muted = muted
        self.duckDuringSpeech = duckDuringSpeech
    }

    enum CodingKeys: String, CodingKey {
        case relativePath, volume, muted, duckDuringSpeech
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.relativePath = try container.decodeIfPresent(String.self, forKey: .relativePath)
        self.volume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? 0.08
        self.muted = try container.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        self.duckDuringSpeech = try container.decodeIfPresent(Bool.self, forKey: .duckDuringSpeech) ?? true
    }
}

public enum MicrophoneAudioPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case off = "channel-fix"
    case standard = "voice"
    case loud = "loud"
    case noiseReduction = "noise-reduction"
    case podcast = "podcast"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .off: return String(localized: "Off")
        case .standard: return String(localized: "Standard")
        case .loud: return String(localized: "Loud")
        case .noiseReduction: return String(localized: "Noise reduction")
        case .podcast: return String(localized: "Podcast")
        }
    }

    public var descriptionText: String {
        switch self {
        case .off:
            return String(localized: "Plays your microphone as recorded.")
        case .standard:
            return String(localized: "Adjusts your voice to a consistent volume. Its character stays the same.")
        case .loud:
            return String(localized: "Boosts your voice to a consistent, loud volume.")
        case .noiseReduction:
            return String(localized: "Boosts your voice and reduces background noise and room echo.")
        case .podcast:
            return String(localized: "Gives your voice the depth and clarity of a studio recording. Done locally on device.")
        }
    }
}

public struct AudioConfig: Codable, Equatable, Hashable, Sendable {
    public var masterVolume: Double
    public var microphoneVolume: Double
    public var muteMicrophone: Bool
    public var microphoneAudioPreset: MicrophoneAudioPreset
    public var voiceEnhancement: Bool
    public var systemAudioVolume: Double
    public var muteSystemAudio: Bool
    public var backgroundMusic: BackgroundMusicConfig

    public init(
        masterVolume: Double = 1.0,
        microphoneVolume: Double = 1.0,
        muteMicrophone: Bool = false,
        microphoneAudioPreset: MicrophoneAudioPreset = .standard,
        voiceEnhancement: Bool = true,
        systemAudioVolume: Double = 1.0,
        muteSystemAudio: Bool = false,
        backgroundMusic: BackgroundMusicConfig = BackgroundMusicConfig()
    ) {
        self.masterVolume = masterVolume
        self.microphoneVolume = microphoneVolume
        self.muteMicrophone = muteMicrophone
        self.microphoneAudioPreset = microphoneAudioPreset
        self.voiceEnhancement = voiceEnhancement
        self.systemAudioVolume = systemAudioVolume
        self.muteSystemAudio = muteSystemAudio
        self.backgroundMusic = backgroundMusic
    }

    enum CodingKeys: String, CodingKey {
        case masterVolume, microphoneVolume, muteMicrophone, microphoneAudioPreset
        case voiceEnhancement, systemAudioVolume, muteSystemAudio, backgroundMusic
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.masterVolume = try container.decodeIfPresent(Double.self, forKey: .masterVolume) ?? 1.0
        self.microphoneVolume = try container.decodeIfPresent(Double.self, forKey: .microphoneVolume) ?? 1.0
        self.muteMicrophone = try container.decodeIfPresent(Bool.self, forKey: .muteMicrophone) ?? false
        self.microphoneAudioPreset = try container.decodeIfPresent(MicrophoneAudioPreset.self, forKey: .microphoneAudioPreset) ?? .standard
        self.voiceEnhancement = try container.decodeIfPresent(Bool.self, forKey: .voiceEnhancement) ?? true
        self.systemAudioVolume = try container.decodeIfPresent(Double.self, forKey: .systemAudioVolume) ?? 1.0
        self.muteSystemAudio = try container.decodeIfPresent(Bool.self, forKey: .muteSystemAudio) ?? false
        self.backgroundMusic = try container.decodeIfPresent(BackgroundMusicConfig.self, forKey: .backgroundMusic) ?? BackgroundMusicConfig()
    }
}

public enum CaptionFontStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case sansSerif = "sans-serif"
    case serif = "serif"
    case mono = "mono"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .sansSerif: return String(localized: "Sans-serif")
        case .serif: return String(localized: "Serif")
        case .mono: return String(localized: "Mono")
        }
    }
}

public enum CaptionWordsReveal: String, Codable, CaseIterable, Identifiable, Sendable {
    case lineByLine = "line-by-line"
    case wordByWord = "word-by-word"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .lineByLine: return String(localized: "Line by line")
        case .wordByWord: return String(localized: "Word by word")
        }
    }

    public var descriptionText: String {
        switch self {
        case .lineByLine:
            return String(localized: "Show whole caption lines as their words are spoken.")
        case .wordByWord:
            return String(localized: "Show one word at a time. Each spoken word pushes the previous one out.")
        }
    }
}

public enum CaptionLineGrowth: String, Codable, CaseIterable, Identifiable, Sendable {
    case fullLine = "entire-line"
    case expanding = "left-anchored"
    case centered = "centered"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .fullLine: return String(localized: "Full line")
        case .expanding: return String(localized: "Expanding")
        case .centered: return String(localized: "Centered")
        }
    }

    public var descriptionText: String {
        switch self {
        case .fullLine:
            return String(localized: "The line box appears at its full size right away.")
        case .expanding:
            return String(localized: "The line box grows from its left edge as words are spoken.")
        case .centered:
            return String(localized: "The line box grows while staying centered as words are spoken.")
        }
    }
}

public enum CaptionWordAnimation: String, Codable, CaseIterable, Identifiable, Sendable {
    case appear = "appear"
    case fadeIn = "fade-in"
    case slideIn = "slide-in"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .appear: return String(localized: "Appear")
        case .fadeIn: return String(localized: "Fade in")
        case .slideIn: return String(localized: "Slide in")
        }
    }

    public var descriptionText: String {
        switch self {
        case .appear:
            return String(localized: "Words pop in as they are spoken.")
        case .fadeIn:
            return String(localized: "Upcoming words are shown dimmed and light up when spoken.")
        case .slideIn:
            return String(localized: "Words slide into place as they are spoken.")
        }
    }
}

public enum CaptionColorTheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case dark = "dark"
    case light = "light"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .dark: return String(localized: "Dark")
        case .light: return String(localized: "Light")
        }
    }
}

public struct CaptionSegment: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var sourceStartMs: Double
    public var sourceEndMs: Double
    public var text: String
    public var isHidden: Bool

    public init(
        id: String = UUID().uuidString,
        sourceStartMs: Double,
        sourceEndMs: Double,
        text: String,
        isHidden: Bool = false
    ) {
        self.id = id
        self.sourceStartMs = sourceStartMs
        self.sourceEndMs = sourceEndMs
        self.text = text
        self.isHidden = isHidden
    }

    enum CodingKeys: String, CodingKey {
        case id, sourceStartMs, sourceEndMs, text, isHidden
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.sourceStartMs = try container.decode(Double.self, forKey: .sourceStartMs)
        self.sourceEndMs = try container.decode(Double.self, forKey: .sourceEndMs)
        self.text = try container.decode(String.self, forKey: .text)
        self.isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
    }
}

public enum ShortcutDockPosition: String, Codable, CaseIterable, Identifiable, Sendable {
    case bottom = "bottom"
    case top = "top"
    case left = "left"
    case right = "right"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .bottom: return String(localized: "Bottom")
        case .top: return String(localized: "Top")
        case .left: return String(localized: "Left")
        case .right: return String(localized: "Right")
        }
    }

    public var iconName: String {
        switch self {
        case .bottom: return "Dock.rectangle"
        case .top: return "menubar.rectangle"
        case .left: return "sidebar.left"
        case .right: return "sidebar.right"
        }
    }

    public var isVerticalStack: Bool {
        self == .left || self == .right
    }
}

public enum ShortcutColorMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case defaultDark = "default"
    case solid = "solid"
    case gradient = "gradient"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .defaultDark: return String(localized: "Default")
        case .solid: return String(localized: "Solid")
        case .gradient: return String(localized: "Gradient")
        }
    }
}

public struct ShortcutStyleConfig: Codable, Equatable, Hashable, Sendable {
    public var dockPosition: ShortcutDockPosition
    public var offsetX: Double // -0.45 ... +0.45 normalized canvas offset
    public var offsetY: Double // -0.45 ... +0.45 normalized canvas offset
    public var colorMode: ShortcutColorMode
    public var solidColorHex: String
    public var gradientStartHex: String
    public var gradientEndHex: String
    public var textColorHex: String

    public init(
        dockPosition: ShortcutDockPosition = .bottom,
        offsetX: Double = 0.0,
        offsetY: Double = 0.0,
        colorMode: ShortcutColorMode = .defaultDark,
        solidColorHex: String = "#4D2FF5",
        gradientStartHex: String = "#4776E6",
        gradientEndHex: String = "#8E54E9",
        textColorHex: String = "#FFFFFF"
    ) {
        self.dockPosition = dockPosition
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.colorMode = colorMode
        self.solidColorHex = solidColorHex
        self.gradientStartHex = gradientStartHex
        self.gradientEndHex = gradientEndHex
        self.textColorHex = textColorHex
    }
}

public struct ShortcutTrackConfig: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var isHidden: Bool
    public var style: ShortcutStyleConfig

    public init(
        id: String = UUID().uuidString,
        name: String = "Shortcuts",
        isHidden: Bool = false,
        style: ShortcutStyleConfig = ShortcutStyleConfig()
    ) {
        self.id = id
        self.name = name
        self.isHidden = isHidden
        self.style = style
    }
}

public struct CustomShortcutSegment: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var trackId: String
    public var sourceStartMs: Double
    public var sourceEndMs: Double
    public var modifiers: [String] // Canonical: ["CapsLock", "Meta", "Shift", "Alt", "Ctrl"]
    public var primaryKey: String
    public var isHidden: Bool
    public var customStyle: ShortcutStyleConfig?

    public init(
        id: String = UUID().uuidString,
        trackId: String = "default-shortcuts-track",
        sourceStartMs: Double,
        sourceEndMs: Double,
        modifiers: [String] = ["Meta"],
        primaryKey: String = "K",
        isHidden: Bool = false,
        customStyle: ShortcutStyleConfig? = nil
    ) {
        self.id = id
        self.trackId = trackId
        self.sourceStartMs = sourceStartMs
        self.sourceEndMs = sourceEndMs
        self.modifiers = modifiers
        self.primaryKey = primaryKey
        self.isHidden = isHidden
        self.customStyle = customStyle
    }
}

/// Look of a caption track, or of one caption that overrides its track.
public struct CaptionStyle: Codable, Equatable, Hashable, Sendable {
    public var fontStyle: CaptionFontStyle
    public var fontSizeRatio: Double // Share of the canvas's shortest side
    public var wordsReveal: CaptionWordsReveal
    public var lineGrowth: CaptionLineGrowth
    public var wordAnimation: CaptionWordAnimation
    public var colorTheme: CaptionColorTheme
    /// Where the line sits inside the canvas margins: `(0, 0)` is the top-left corner, `(1, 1)` the bottom-right.
    public var position01: Point01

    public static let bottomPosition01 = Point01(x: 0.5, y: 1.0)
    public static let centerPosition01 = Point01(x: 0.5, y: 0.5)

    public init(
        fontStyle: CaptionFontStyle = .sansSerif,
        fontSizeRatio: Double = 0.045,
        wordsReveal: CaptionWordsReveal = .lineByLine,
        lineGrowth: CaptionLineGrowth = .expanding,
        wordAnimation: CaptionWordAnimation = .appear,
        colorTheme: CaptionColorTheme = .dark,
        position01: Point01 = CaptionStyle.bottomPosition01
    ) {
        self.fontStyle = fontStyle
        self.fontSizeRatio = fontSizeRatio
        self.wordsReveal = wordsReveal
        self.lineGrowth = lineGrowth
        self.wordAnimation = wordAnimation
        self.colorTheme = colorTheme
        self.position01 = position01
    }
}

public struct CaptionTrack: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var isHidden: Bool
    public var style: CaptionStyle

    public init(id: String = UUID().uuidString, name: String, isHidden: Bool = false, style: CaptionStyle = CaptionStyle()) {
        self.id = id
        self.name = name
        self.isHidden = isHidden
        self.style = style
    }
}

/// One caption on a track. Its timing is separate from the words' spoken times, so moving a caption
/// never changes what `Edit by transcript` cuts. Words are stretched to fit `sourceStartMs ... sourceEndMs`.
public struct CaptionBlock: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var trackId: String
    public var sourceStartMs: Double
    public var sourceEndMs: Double
    /// Transcript words shown by this caption. Empty when `customText` is set.
    public var wordIds: [String]
    /// Text typed by hand, or a transcript caption whose word count was changed.
    public var customText: String?
    public var styleOverride: CaptionStyle?

    public init(
        id: String = UUID().uuidString,
        trackId: String,
        sourceStartMs: Double,
        sourceEndMs: Double,
        wordIds: [String] = [],
        customText: String? = nil,
        styleOverride: CaptionStyle? = nil
    ) {
        self.id = id
        self.trackId = trackId
        self.sourceStartMs = sourceStartMs
        self.sourceEndMs = sourceEndMs
        self.wordIds = wordIds
        self.customText = customText
        self.styleOverride = styleOverride
    }
}

public struct CaptionsConfig: Codable, Equatable, Hashable, Sendable {
    public var enabled: Bool
    public var showKeystrokes: Bool
    public var shortcutsSizeRatio: Double
    public var showSingleKeyShortcuts: Bool
    public var hiddenShortcutStartMs: [Int]
    public var deletedShortcutStartMs: [Int]
    public var defaultShortcutStyle: ShortcutStyleConfig
    public var shortcutTracks: [ShortcutTrackConfig]
    public var customShortcuts: [CustomShortcutSegment]
    public var shortcutStyleOverrides: [String: ShortcutStyleConfig]
    public var shortcutTimingOverrides: [Int: Point01]
    public var shortcutKeyOverrides: [Int: CustomShortcutSegment]
    public var keystrokesPosition01: Point01
    public var fontFamily: String
    public var fontStyle: CaptionFontStyle
    public var fontSizeRatio: Double
    public var wordsReveal: CaptionWordsReveal
    public var lineGrowth: CaptionLineGrowth
    public var wordAnimation: CaptionWordAnimation
    public var colorTheme: CaptionColorTheme
    public var textColor: String
    public var backgroundColor: String
    public var position01: Point01
    public var animationStyle: String
    public var transcriptLocale: String
    public var localModelVariant: String
    public var whisperModelTier: String
    public var customPrompt: String
    public var showDeletedTextInTranscript: Bool
    public var showHiddenWordsInTranscript: Bool
    public var segments: [CaptionSegment]
    public var captionTracks: [CaptionTrack]
    public var captionBlocks: [CaptionBlock]

    public init(
        enabled: Bool = false,
        showKeystrokes: Bool = true,
        shortcutsSizeRatio: Double = 0.11,
        showSingleKeyShortcuts: Bool = false,
        hiddenShortcutStartMs: [Int] = [],
        deletedShortcutStartMs: [Int] = [],
        defaultShortcutStyle: ShortcutStyleConfig = ShortcutStyleConfig(),
        shortcutTracks: [ShortcutTrackConfig] = [],
        customShortcuts: [CustomShortcutSegment] = [],
        shortcutStyleOverrides: [String: ShortcutStyleConfig] = [:],
        shortcutTimingOverrides: [Int: Point01] = [:],
        shortcutKeyOverrides: [Int: CustomShortcutSegment] = [:],
        keystrokesPosition01: Point01 = Point01(x: 0.5, y: 0.90),
        fontFamily: String = "SF Pro Rounded",
        fontStyle: CaptionFontStyle = .sansSerif,
        fontSizeRatio: Double = 0.045,
        wordsReveal: CaptionWordsReveal = .lineByLine,
        lineGrowth: CaptionLineGrowth = .expanding,
        wordAnimation: CaptionWordAnimation = .appear,
        colorTheme: CaptionColorTheme = .dark,
        textColor: String = "#FFFFFF",
        backgroundColor: String = "#000000CC",
        position01: Point01 = Point01(x: 0.5, y: 0.88),
        animationStyle: String = "word-by-word",
        transcriptLocale: String = "en_US",
        localModelVariant: String = "system",
        whisperModelTier: String = "small",
        customPrompt: String = "",
        showDeletedTextInTranscript: Bool = true,
        showHiddenWordsInTranscript: Bool = true,
        segments: [CaptionSegment] = [],
        captionTracks: [CaptionTrack] = [],
        captionBlocks: [CaptionBlock] = []
    ) {
        self.enabled = enabled
        self.showKeystrokes = showKeystrokes
        self.shortcutsSizeRatio = shortcutsSizeRatio
        self.showSingleKeyShortcuts = showSingleKeyShortcuts
        self.hiddenShortcutStartMs = hiddenShortcutStartMs
        self.deletedShortcutStartMs = deletedShortcutStartMs
        self.defaultShortcutStyle = defaultShortcutStyle
        self.shortcutTracks = shortcutTracks
        self.customShortcuts = customShortcuts
        self.shortcutStyleOverrides = shortcutStyleOverrides
        self.shortcutTimingOverrides = shortcutTimingOverrides
        self.shortcutKeyOverrides = shortcutKeyOverrides
        self.keystrokesPosition01 = keystrokesPosition01
        self.fontFamily = fontFamily
        self.fontStyle = fontStyle
        self.fontSizeRatio = fontSizeRatio
        self.wordsReveal = wordsReveal
        self.lineGrowth = lineGrowth
        self.wordAnimation = wordAnimation
        self.colorTheme = colorTheme
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.position01 = position01
        self.animationStyle = animationStyle
        self.transcriptLocale = transcriptLocale
        self.localModelVariant = localModelVariant
        self.whisperModelTier = whisperModelTier
        self.customPrompt = customPrompt
        self.showDeletedTextInTranscript = showDeletedTextInTranscript
        self.showHiddenWordsInTranscript = showHiddenWordsInTranscript
        self.segments = segments
        self.captionTracks = captionTracks
        self.captionBlocks = captionBlocks
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case showKeystrokes
        case shortcutsSizeRatio
        case showSingleKeyShortcuts
        case hiddenShortcutStartMs
        case deletedShortcutStartMs
        case defaultShortcutStyle
        case shortcutTracks
        case customShortcuts
        case shortcutStyleOverrides
        case shortcutTimingOverrides
        case shortcutKeyOverrides
        case keystrokesPosition01
        case fontFamily
        case fontStyle
        case fontSizeRatio
        case wordsReveal
        case lineGrowth
        case wordAnimation
        case colorTheme
        case textColor
        case backgroundColor
        case position01
        case animationStyle
        case transcriptLocale
        case localModelVariant
        case whisperModelTier
        case customPrompt
        case showDeletedTextInTranscript
        case showHiddenWordsInTranscript
        case segments
        case captionTracks
        case captionBlocks
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.showKeystrokes = try container.decodeIfPresent(Bool.self, forKey: .showKeystrokes) ?? true
        self.shortcutsSizeRatio = try container.decodeIfPresent(Double.self, forKey: .shortcutsSizeRatio) ?? 0.11
        self.showSingleKeyShortcuts = try container.decodeIfPresent(Bool.self, forKey: .showSingleKeyShortcuts) ?? false
        self.hiddenShortcutStartMs = try container.decodeIfPresent([Int].self, forKey: .hiddenShortcutStartMs) ?? []
        self.deletedShortcutStartMs = try container.decodeIfPresent([Int].self, forKey: .deletedShortcutStartMs) ?? []
        let defStyle = try container.decodeIfPresent(ShortcutStyleConfig.self, forKey: .defaultShortcutStyle) ?? ShortcutStyleConfig()
        self.defaultShortcutStyle = defStyle
        self.shortcutTracks = try container.decodeIfPresent([ShortcutTrackConfig].self, forKey: .shortcutTracks) ?? []
        self.customShortcuts = try container.decodeIfPresent([CustomShortcutSegment].self, forKey: .customShortcuts) ?? []
        self.shortcutStyleOverrides = try container.decodeIfPresent([String: ShortcutStyleConfig].self, forKey: .shortcutStyleOverrides) ?? [:]
        self.shortcutTimingOverrides = try container.decodeIfPresent([Int: Point01].self, forKey: .shortcutTimingOverrides) ?? [:]
        self.shortcutKeyOverrides = try container.decodeIfPresent([Int: CustomShortcutSegment].self, forKey: .shortcutKeyOverrides) ?? [:]
        self.keystrokesPosition01 = try container.decodeIfPresent(Point01.self, forKey: .keystrokesPosition01) ?? Point01(x: 0.5, y: 0.90)
        self.fontFamily = try container.decodeIfPresent(String.self, forKey: .fontFamily) ?? "SF Pro Rounded"
        self.fontStyle = try container.decodeIfPresent(CaptionFontStyle.self, forKey: .fontStyle) ?? .sansSerif
        self.fontSizeRatio = try container.decodeIfPresent(Double.self, forKey: .fontSizeRatio) ?? 0.045
        self.wordsReveal = try container.decodeIfPresent(CaptionWordsReveal.self, forKey: .wordsReveal) ?? .lineByLine
        self.lineGrowth = try container.decodeIfPresent(CaptionLineGrowth.self, forKey: .lineGrowth) ?? .expanding
        self.wordAnimation = try container.decodeIfPresent(CaptionWordAnimation.self, forKey: .wordAnimation) ?? .appear
        self.colorTheme = try container.decodeIfPresent(CaptionColorTheme.self, forKey: .colorTheme) ?? .dark
        self.textColor = try container.decodeIfPresent(String.self, forKey: .textColor) ?? "#FFFFFF"
        self.backgroundColor = try container.decodeIfPresent(String.self, forKey: .backgroundColor) ?? "#000000CC"
        self.position01 = try container.decodeIfPresent(Point01.self, forKey: .position01) ?? Point01(x: 0.5, y: 0.88)
        self.animationStyle = try container.decodeIfPresent(String.self, forKey: .animationStyle) ?? "word-by-word"
        self.transcriptLocale = try container.decodeIfPresent(String.self, forKey: .transcriptLocale) ?? "en_US"
        self.localModelVariant = try container.decodeIfPresent(String.self, forKey: .localModelVariant) ?? "system"
        self.whisperModelTier = try container.decodeIfPresent(String.self, forKey: .whisperModelTier) ?? "small"
        self.customPrompt = try container.decodeIfPresent(String.self, forKey: .customPrompt) ?? ""
        self.showDeletedTextInTranscript = try container.decodeIfPresent(Bool.self, forKey: .showDeletedTextInTranscript) ?? true
        self.showHiddenWordsInTranscript = try container.decodeIfPresent(Bool.self, forKey: .showHiddenWordsInTranscript) ?? true
        self.segments = try container.decodeIfPresent([CaptionSegment].self, forKey: .segments) ?? []
        self.captionTracks = try container.decodeIfPresent([CaptionTrack].self, forKey: .captionTracks) ?? []
        self.captionBlocks = try container.decodeIfPresent([CaptionBlock].self, forKey: .captionBlocks) ?? []
    }

    /// Projects saved before caption tracks keep their look: the old project-wide style becomes the first track's style.
    public mutating func migrateTranscriptToCaptionTracksIfNeeded() {
        guard captionTracks.isEmpty, !segments.isEmpty else { return }
        captionTracks = [
            CaptionTrack(
                name: "Captions",
                style: CaptionStyle(
                    fontStyle: fontStyle,
                    fontSizeRatio: fontSizeRatio,
                    wordsReveal: wordsReveal,
                    lineGrowth: lineGrowth,
                    wordAnimation: wordAnimation,
                    colorTheme: colorTheme,
                    position01: position01
                )
            )
        ]
        rebuildTranscriptCaptionBlocks()
    }

    /// A track always holds a caption. The rest are numbered by position.
    public mutating func removeEmptyCaptionTracks() {
        let usedTrackIds = Set(captionBlocks.map(\.trackId))
        captionTracks.removeAll { !usedTrackIds.contains($0.id) }
        for idx in captionTracks.indices {
            captionTracks[idx].name = idx == 0 ? "Captions" : "Captions \(idx + 1)"
        }
    }

    /// Fills the first track from the transcript. Captions typed by hand on other tracks stay.
    public mutating func rebuildTranscriptCaptionBlocks() {
        if captionTracks.isEmpty {
            captionTracks = [CaptionTrack(name: "Captions")]
        }
        let trackId = captionTracks[0].id
        captionBlocks.removeAll { !$0.wordIds.isEmpty || $0.trackId == trackId }
        captionBlocks += CaptionLineLayout.groupWordsIntoLines(segments).compactMap { words in
            guard let first = words.first, let last = words.last else { return nil }
            return CaptionBlock(
                trackId: trackId,
                sourceStartMs: first.sourceStartMs,
                sourceEndMs: last.sourceEndMs,
                wordIds: words.map(\.id)
            )
        }
    }
}

// MARK: - NLE Timeline Models (Slices, Zooms, Multi-Track Masks)

public struct ClipSlice: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var sourceStartMs: Double
    public var sourceEndMs: Double
    public var speed: Double
    public var systemAudioVolume: Double
    /// Multiplies `audio.microphoneVolume` while this slice plays. Missing in files from older builds, read as 1.
    public var microphoneVolume: Double
    public var muted: Bool
    public var hideCursor: Bool
    public var disableSmoothCursor: Bool

    public init(
        id: String = UUID().uuidString,
        sourceStartMs: Double,
        sourceEndMs: Double,
        speed: Double = 1.0,
        systemAudioVolume: Double = 1.0,
        microphoneVolume: Double = 1.0,
        muted: Bool = false,
        hideCursor: Bool = false,
        disableSmoothCursor: Bool = false
    ) {
        self.id = id
        self.sourceStartMs = sourceStartMs
        self.sourceEndMs = sourceEndMs
        self.speed = max(0.1, speed)
        self.systemAudioVolume = max(0.0, min(2.0, systemAudioVolume))
        self.microphoneVolume = max(0.0, min(2.0, microphoneVolume))
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
        case microphoneVolume
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
        self.microphoneVolume = max(0.0, min(2.0, try container.decodeIfPresent(Double.self, forKey: .microphoneVolume) ?? 1.0))
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
    public var instantAnimation: Bool
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
        instantAnimation: Bool = false,
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
        self.instantAnimation = instantAnimation
        self.disabled = disabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, sourceStartMs, sourceEndMs, scale, mode, presentation, manualCenter01, loupe, instantAnimation, disabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.sourceStartMs = try container.decode(Double.self, forKey: .sourceStartMs)
        self.sourceEndMs = try container.decode(Double.self, forKey: .sourceEndMs)
        self.scale = try container.decodeIfPresent(Double.self, forKey: .scale) ?? 1.8
        self.mode = try container.decodeIfPresent(ZoomMode.self, forKey: .mode) ?? .followCursor
        self.presentation = try container.decodeIfPresent(ZoomPresentation.self, forKey: .presentation) ?? .screen
        self.manualCenter01 = try container.decodeIfPresent(Point01.self, forKey: .manualCenter01) ?? .center
        self.loupe = try container.decodeIfPresent(LoupeConfig.self, forKey: .loupe) ?? LoupeConfig()
        self.instantAnimation = try container.decodeIfPresent(Bool.self, forKey: .instantAnimation) ?? false
        self.disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
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
    public var isAutoSensitiveMask: Bool
    public var isAutoFaceMask: Bool

    public init(
        id: String = UUID().uuidString,
        sourceStartMs: Double,
        sourceEndMs: Double,
        type: MaskType = .blur,
        style: MaskStyle = .gaussian,
        intensity: Double = 36.0,
        cornerRadius: Double = 10.0,
        keyframes: [MaskKeyframe],
        disabled: Bool = false,
        isAutoSensitiveMask: Bool = false,
        isAutoFaceMask: Bool = false
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
        self.isAutoSensitiveMask = isAutoSensitiveMask
        self.isAutoFaceMask = isAutoFaceMask
    }

    enum CodingKeys: String, CodingKey {
        case id, sourceStartMs, sourceEndMs, type, style, intensity, cornerRadius, keyframes, disabled
        case isAutoSensitiveMask, isAutoFaceMask
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.sourceStartMs = try container.decode(Double.self, forKey: .sourceStartMs)
        self.sourceEndMs = try container.decode(Double.self, forKey: .sourceEndMs)
        self.type = try container.decodeIfPresent(MaskType.self, forKey: .type) ?? .blur
        self.style = try container.decodeIfPresent(MaskStyle.self, forKey: .style) ?? .gaussian
        self.intensity = try container.decodeIfPresent(Double.self, forKey: .intensity) ?? 36.0
        self.cornerRadius = try container.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 10.0
        self.keyframes = try container.decodeIfPresent([MaskKeyframe].self, forKey: .keyframes) ?? []
        self.disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
        self.isAutoSensitiveMask = try container.decodeIfPresent(Bool.self, forKey: .isAutoSensitiveMask) ?? false
        self.isAutoFaceMask = try container.decodeIfPresent(Bool.self, forKey: .isAutoFaceMask) ?? false
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

// MARK: - Camera Layouts Track & Voiceovers Track Models

public enum CameraTimelineLayoutType: String, Codable, CaseIterable, Identifiable, Sendable {
    case cameraOverlay = "camera-overlay"
    case splitScreen = "split-screen"
    case cutoutCamera = "cutout-camera"
    case fullscreenCamera = "fullscreen-camera"
    case screenOnly = "screen-only"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .cameraOverlay: return String(localized: "Camera overlay")
        case .splitScreen: return String(localized: "Split screen")
        case .cutoutCamera: return String(localized: "Camera cutout")
        case .fullscreenCamera: return String(localized: "Fullscreen camera")
        case .screenOnly: return String(localized: "Only screen")
        }
    }

    public var timelineSubtitle: String {
        switch self {
        case .cameraOverlay: return String(localized: "Camera overlay")
        case .splitScreen: return String(localized: "Split screen")
        case .cutoutCamera: return String(localized: "Camera cutout")
        case .fullscreenCamera: return String(localized: "Fullscreen")
        case .screenOnly: return String(localized: "Screen only")
        }
    }

    public var quickDockIcon: String {
        switch self {
        case .cameraOverlay: return "inset.filled.rectangle.and.person.filled"
        case .splitScreen: return "rectangle.split.2x1.fill"
        case .cutoutCamera: return "person.crop.rectangle.stack"
        case .fullscreenCamera: return "person.crop.rectangle.fill"
        case .screenOnly: return "display"
        }
    }
}

public struct CameraLayoutSegment: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var sourceStartMs: Double
    public var sourceEndMs: Double
    public var layoutType: CameraTimelineLayoutType
    public var overlayPosition01: Point01?
    public var cutoutPositionX01: Double?
    public var disabled: Bool

    public init(
        id: String = UUID().uuidString,
        sourceStartMs: Double,
        sourceEndMs: Double,
        layoutType: CameraTimelineLayoutType = .cameraOverlay,
        overlayPosition01: Point01? = nil,
        cutoutPositionX01: Double? = nil,
        disabled: Bool = false
    ) {
        self.id = id
        self.sourceStartMs = sourceStartMs
        self.sourceEndMs = sourceEndMs
        self.layoutType = layoutType
        self.overlayPosition01 = overlayPosition01
        self.cutoutPositionX01 = cutoutPositionX01
        self.disabled = disabled
    }

    enum CodingKeys: String, CodingKey {
        case id, sourceStartMs, sourceEndMs, layoutType, overlayPosition01, cutoutPositionX01, disabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.sourceStartMs = try container.decode(Double.self, forKey: .sourceStartMs)
        self.sourceEndMs = try container.decode(Double.self, forKey: .sourceEndMs)
        self.layoutType = try container.decodeIfPresent(CameraTimelineLayoutType.self, forKey: .layoutType) ?? .cameraOverlay
        self.overlayPosition01 = try container.decodeIfPresent(Point01.self, forKey: .overlayPosition01)
        self.cutoutPositionX01 = try container.decodeIfPresent(Double.self, forKey: .cutoutPositionX01)
        self.disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
    }
}

public enum VoiceoverAttachMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case independent = "first-frame"
    case synchronized = "all-frames"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .independent: return String(localized: "Independent")
        case .synchronized: return String(localized: "Synchronized")
        }
    }

    public var descriptionText: String {
        switch self {
        case .independent:
            return String(localized: "Voiceover plays independently of the recording, even if the recording speed is changed or parts of the recording are cut out.")
        case .synchronized:
            return String(localized: "Voiceover plays along with the recording. Voiceover automatically adjusts to the recording speed and is cut out if parts of the recording are cut out.")
        }
    }
}

public struct VoiceoverSegment: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var sourceStartMs: Double
    public var durationMs: Double
    public var relativePath: String
    public var volume: Double
    public var attachMode: VoiceoverAttachMode
    public var hideRecording: Bool
    public var disabled: Bool
    public var trackIndex: Int

    public var sourceEndMs: Double {
        sourceStartMs + max(200.0, durationMs)
    }

    public init(
        id: String = UUID().uuidString,
        sourceStartMs: Double,
        durationMs: Double,
        relativePath: String,
        volume: Double = 1.0,
        attachMode: VoiceoverAttachMode = .synchronized,
        hideRecording: Bool = false,
        disabled: Bool = false,
        trackIndex: Int = 0
    ) {
        self.id = id
        self.sourceStartMs = sourceStartMs
        self.durationMs = max(200.0, durationMs)
        self.relativePath = relativePath
        self.volume = max(0.0, min(1.0, volume))
        self.attachMode = attachMode
        self.hideRecording = hideRecording
        self.disabled = disabled
        self.trackIndex = max(0, trackIndex)
    }

    enum CodingKeys: String, CodingKey {
        case id, sourceStartMs, durationMs, relativePath, volume, attachMode, hideRecording, disabled, trackIndex
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.sourceStartMs = try container.decode(Double.self, forKey: .sourceStartMs)
        self.durationMs = max(200.0, try container.decodeIfPresent(Double.self, forKey: .durationMs) ?? 2000.0)
        self.relativePath = try container.decodeIfPresent(String.self, forKey: .relativePath) ?? ""
        self.volume = max(0.0, min(1.0, try container.decodeIfPresent(Double.self, forKey: .volume) ?? 1.0))
        self.attachMode = try container.decodeIfPresent(VoiceoverAttachMode.self, forKey: .attachMode) ?? .synchronized
        self.hideRecording = try container.decodeIfPresent(Bool.self, forKey: .hideRecording) ?? false
        self.disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
        self.trackIndex = max(0, try container.decodeIfPresent(Int.self, forKey: .trackIndex) ?? 0)
    }
}

public struct TimelineConfig: Codable, Equatable, Hashable, Sendable {
    public var slices: [ClipSlice]
    public var zooms: [ZoomBlock]
    public var isZoomTrackHidden: Bool
    public var cameraLayouts: [CameraLayoutSegment]
    public var isCameraLayoutsTrackHidden: Bool
    public var maskTracks: [MaskTrack]
    public var voiceovers: [VoiceoverSegment]
    public var isVoiceoversTrackHidden: Bool
    public var hiddenVoiceoverTracks: [Int]
    public var isShortcutsTrackHidden: Bool
    public var dismissedTypingSuggestionStarts: [Int]

    public init(
        slices: [ClipSlice] = [],
        zooms: [ZoomBlock] = [],
        isZoomTrackHidden: Bool = false,
        cameraLayouts: [CameraLayoutSegment] = [],
        isCameraLayoutsTrackHidden: Bool = false,
        maskTracks: [MaskTrack] = [],
        voiceovers: [VoiceoverSegment] = [],
        isVoiceoversTrackHidden: Bool = false,
        hiddenVoiceoverTracks: [Int] = [],
        isShortcutsTrackHidden: Bool = false,
        dismissedTypingSuggestionStarts: [Int] = []
    ) {
        self.slices = slices
        self.zooms = zooms
        self.isZoomTrackHidden = isZoomTrackHidden
        self.cameraLayouts = cameraLayouts
        self.isCameraLayoutsTrackHidden = isCameraLayoutsTrackHidden
        self.maskTracks = maskTracks
        self.voiceovers = voiceovers
        self.isVoiceoversTrackHidden = isVoiceoversTrackHidden
        self.hiddenVoiceoverTracks = hiddenVoiceoverTracks
        self.isShortcutsTrackHidden = isShortcutsTrackHidden
        self.dismissedTypingSuggestionStarts = dismissedTypingSuggestionStarts
    }

    enum CodingKeys: String, CodingKey {
        case slices, zooms, isZoomTrackHidden, cameraLayouts, isCameraLayoutsTrackHidden
        case maskTracks, voiceovers, isVoiceoversTrackHidden, hiddenVoiceoverTracks, isShortcutsTrackHidden, dismissedTypingSuggestionStarts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.slices = try container.decodeIfPresent([ClipSlice].self, forKey: .slices) ?? []
        self.zooms = try container.decodeIfPresent([ZoomBlock].self, forKey: .zooms) ?? []
        self.isZoomTrackHidden = try container.decodeIfPresent(Bool.self, forKey: .isZoomTrackHidden) ?? false
        self.cameraLayouts = try container.decodeIfPresent([CameraLayoutSegment].self, forKey: .cameraLayouts) ?? []
        self.isCameraLayoutsTrackHidden = try container.decodeIfPresent(Bool.self, forKey: .isCameraLayoutsTrackHidden) ?? false
        self.maskTracks = try container.decodeIfPresent([MaskTrack].self, forKey: .maskTracks) ?? []
        self.voiceovers = try container.decodeIfPresent([VoiceoverSegment].self, forKey: .voiceovers) ?? []
        self.isVoiceoversTrackHidden = try container.decodeIfPresent(Bool.self, forKey: .isVoiceoversTrackHidden) ?? false
        self.hiddenVoiceoverTracks = try container.decodeIfPresent([Int].self, forKey: .hiddenVoiceoverTracks) ?? []
        self.isShortcutsTrackHidden = try container.decodeIfPresent(Bool.self, forKey: .isShortcutsTrackHidden) ?? false
        self.dismissedTypingSuggestionStarts = try container.decodeIfPresent([Int].self, forKey: .dismissedTypingSuggestionStarts) ?? []
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
