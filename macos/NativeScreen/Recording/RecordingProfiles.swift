import Foundation
import AppKit
import Observation

/// A named set of recording choices from the HUD. A window cannot be saved (windows come and go), so a profile in
/// window mode keeps the mode and the next window is picked as usual. A camera or microphone that is not connected is
/// skipped, and the current choice stays.
public struct RecordingProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var mode: CaptureTargetMode
    /// Area mode: the area, in Quartz screen coordinates.
    public var areaRect: CGRect?
    public var cameraDeviceID: String?
    public var cameraName: String?
    public var showCameraPreview: Bool
    public var cameraMaxResolution: String
    public var captureMicrophone: Bool
    public var microphoneDeviceID: String?
    public var microphoneName: String?
    public var captureSystemAudio: Bool
    public var systemAudioFromAllApps: Bool
    public var systemAudioAppBundleIDs: [String]
    public var countdownSeconds: Int
    public var hideDesktopIcons: Bool
    public var hideDockIcon: Bool
    public var highlightRecordedArea: Bool
    public var showSpeakerNotes: Bool
}

@Observable
@MainActor
public final class RecordingProfileStore {
    public static let shared = RecordingProfileStore()

    public private(set) var profiles: [RecordingProfile] = []
    private let defaultsKey = "NativeScreen.RecordingProfiles"

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode([RecordingProfile].self, from: data) {
            profiles = saved
        }
    }

    public func save(_ profile: RecordingProfile) {
        profiles.removeAll { $0.name.caseInsensitiveCompare(profile.name) == .orderedSame }
        profiles.append(profile)
        persist()
    }

    public func delete(id: String) {
        profiles.removeAll { $0.id == id }
        persist()
    }

    /// Asks for a profile name. Nil when cancelled or left empty.
    public static func askName() -> String? {
        let alert = NSAlert()
        alert.messageText = String(localized: "Save Profile")
        alert.informativeText = String(localized: "A profile keeps the capture mode, camera, microphone, system audio and recording options, so you can switch setups in one click.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = String(localized: "Profile name")
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

extension RecordingCoordinator {
    public func currentRecordingProfile(named name: String) -> RecordingProfile {
        RecordingProfile(
            id: UUID().uuidString,
            name: name,
            mode: selectedMode,
            areaRect: selectedMode == .area ? selectedAreaRectQuartz : nil,
            cameraDeviceID: selectedCameraDeviceID,
            cameraName: selectedCameraName,
            showCameraPreview: showCameraPreview,
            cameraMaxResolution: cameraMaxResolution.rawValue,
            captureMicrophone: captureMicrophone,
            microphoneDeviceID: selectedMicrophoneDeviceID,
            microphoneName: selectedMicrophoneName,
            captureSystemAudio: captureSystemAudio,
            systemAudioFromAllApps: systemAudioFromAllApps,
            systemAudioAppBundleIDs: selectedSystemAudioAppBundleIDs.sorted(),
            countdownSeconds: countdownOption.rawValue,
            hideDesktopIcons: hideDesktopIcons,
            hideDockIcon: hideDockIcon,
            highlightRecordedArea: highlightRecordedArea,
            showSpeakerNotes: showSpeakerNotes
        )
    }

    /// True when the HUD is set up as `profile` says (ignoring devices that are not connected).
    public func matches(_ profile: RecordingProfile) -> Bool {
        var current = currentRecordingProfile(named: profile.name)
        current.id = profile.id
        var expected = profile
        if let id = profile.cameraDeviceID, !connectedCameras.contains(where: { $0.id == id }) {
            expected.cameraDeviceID = current.cameraDeviceID
            expected.cameraName = current.cameraName
        }
        if let id = profile.microphoneDeviceID, !connectedMicrophones.contains(where: { $0.id == id }) {
            expected.microphoneDeviceID = current.microphoneDeviceID
            expected.microphoneName = current.microphoneName
        }
        if profile.mode != .area { expected.areaRect = nil }
        return current == expected
    }

    public func apply(_ profile: RecordingProfile) {
        guard !isRecording && !isCountingDown else { return }
        refreshConnectedMediaDevices()
        selectedMode = profile.mode
        if profile.mode == .area, let rect = profile.areaRect {
            selectedAreaRectQuartz = rect
        }
        if profile.cameraDeviceID == nil {
            selectedCameraDeviceID = nil
            selectedCameraName = nil
        } else if let id = profile.cameraDeviceID, connectedCameras.contains(where: { $0.id == id }) {
            selectedCameraName = profile.cameraName
            selectedCameraDeviceID = id
        }
        showCameraPreview = profile.showCameraPreview
        cameraMaxResolution = CameraMaxResolutionOption(rawValue: profile.cameraMaxResolution) ?? cameraMaxResolution
        if let id = profile.microphoneDeviceID, connectedMicrophones.contains(where: { $0.id == id }) {
            selectedMicrophoneName = profile.microphoneName
            selectedMicrophoneDeviceID = id
        }
        captureMicrophone = profile.captureMicrophone
        captureSystemAudio = profile.captureSystemAudio
        systemAudioFromAllApps = profile.systemAudioFromAllApps
        selectedSystemAudioAppBundleIDs = Set(profile.systemAudioAppBundleIDs)
        countdownOption = RecordingCountdownOption(rawValue: profile.countdownSeconds) ?? countdownOption
        hideDesktopIcons = profile.hideDesktopIcons
        hideDockIcon = profile.hideDockIcon
        highlightRecordedArea = profile.highlightRecordedArea
        showSpeakerNotes = profile.showSpeakerNotes
    }
}
