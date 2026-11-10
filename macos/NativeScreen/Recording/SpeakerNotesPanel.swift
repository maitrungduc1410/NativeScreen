import AppKit
import SwiftUI

/// Speaker notes: a floating window only the presenter sees. Between recordings it can be screenshotted like any
/// window; when a recording starts it switches to `sharingType = .none` before the capture filter is built, so
/// `RecordingCoordinator` leaves it out like the rest of the recording UI. Turning it on during a recording would put a
/// window the running capture does not know about on screen, so that waits for the next recording.
@Observable
@MainActor
final class SpeakerNotesModel {
    static let shared = SpeakerNotesModel()

    private enum Keys {
        static let text = "NativeScreen.SpeakerNotes.Text"
        static let fontSize = "NativeScreen.SpeakerNotes.FontSize"
        static let speed = "NativeScreen.SpeakerNotes.Speed"
        static let scrollsWhileRecording = "NativeScreen.SpeakerNotes.ScrollsWhileRecording"
    }

    var text: String {
        didSet { UserDefaults.standard.set(text, forKey: Keys.text) }
    }
    var fontSize: Double {
        didSet { UserDefaults.standard.set(fontSize, forKey: Keys.fontSize) }
    }
    /// Points per second.
    var speed: Double {
        didSet { UserDefaults.standard.set(speed, forKey: Keys.speed) }
    }
    var scrollsWhileRecording: Bool {
        didSet { UserDefaults.standard.set(scrollsWhileRecording, forKey: Keys.scrollsWhileRecording) }
    }

    /// Scrolled distance, and when scrolling last started (nil while stopped).
    var offset: Double = 0
    var scrollingSince: Date?
    var isPrompting = false

    static let fontSizeRange: ClosedRange<Double> = 14...64
    static let speedRange: ClosedRange<Double> = 5...120

    private init() {
        let d = UserDefaults.standard
        text = d.string(forKey: Keys.text) ?? ""
        fontSize = d.object(forKey: Keys.fontSize) as? Double ?? 26
        speed = d.object(forKey: Keys.speed) as? Double ?? 30
        scrollsWhileRecording = d.object(forKey: Keys.scrollsWhileRecording) as? Bool ?? true
    }

    func currentOffset(at date: Date) -> Double {
        guard let since = scrollingSince else { return offset }
        return offset + date.timeIntervalSince(since) * speed
    }

    func startScrolling() {
        guard scrollingSince == nil else { return }
        isPrompting = true
        scrollingSince = Date()
    }

    /// Space and the play button: starts the prompter, or pauses it.
    func toggleScrolling() {
        if scrollingSince == nil {
            guard !text.isEmpty else { return }
            startScrolling()
        } else {
            stopScrolling()
        }
    }

    func stopScrolling() {
        guard let since = scrollingSince else { return }
        offset += Date().timeIntervalSince(since) * speed
        scrollingSince = nil
    }

    func backToTop() {
        offset = 0
        if scrollingSince != nil { scrollingSince = Date() }
    }

    /// Keeps the scroll position when the speed changes mid-scroll.
    func setSpeed(_ value: Double) {
        if let since = scrollingSince {
            offset += Date().timeIntervalSince(since) * speed
            scrollingSince = Date()
        }
        speed = min(Self.speedRange.upperBound, max(Self.speedRange.lowerBound, value))
    }
}

@MainActor
final class SpeakerNotesWindowController {
    static let shared = SpeakerNotesWindowController()
    private var panel: NSPanel?
    private var onClose: (() -> Void)?
    private var closeObserver: NSObjectProtocol?
    private var keyMonitor: Any?
    private let frameKey = "NativeScreen.SpeakerNotes.Frame"
    /// The user's frame while the window is docked under the camera, put back when it leaves.
    private var frameBeforeDocking: NSRect?

    var isShown: Bool { panel?.isVisible == true }

    /// `onClose` runs when the user closes the window with its close button.
    func show(near screen: NSScreen?, onClose: @escaping () -> Void) {
        self.onClose = onClose
        if panel == nil {
            let vf = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let size = NSSize(width: 420, height: 320)
            let defaultFrame = NSRect(x: vf.midX - size.width / 2, y: vf.maxY - size.height - 60, width: size.width, height: size.height)
            let panel = NSPanel(
                contentRect: defaultFrame,
                styleMask: [.titled, .closable, .resizable, .utilityWindow, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.title = String(localized: "Speaker Notes")
            panel.titlebarAppearsTransparent = true
            panel.isReleasedWhenClosed = false
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.sharingType = .readOnly // `.none` only while recording (`setHiddenFromCapture`).
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.minSize = NSSize(width: 280, height: 180)
            panel.appearance = NSAppearance(named: .darkAqua)
            panel.setFrameAutosaveName(frameKey)
            panel.contentView = NSHostingView(rootView: SpeakerNotesView(model: .shared))
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    SpeakerNotesModel.shared.stopScrolling()
                    self?.onClose?()
                }
            }
            // Space plays and pauses the prompter while the window is focused, unless the notes are being typed in.
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak panel] event in
                guard let panel, event.window === panel, event.keyCode == 49,
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock).isEmpty,
                      !(panel.firstResponder is NSTextView) else { return event }
                MainActor.assumeIsolated { SpeakerNotesModel.shared.toggleScrolling() }
                return nil
            }
            self.panel = panel
        }
        panel?.orderFrontRegardless()
    }

    /// Off camera while recording; a normal window otherwise, so it shows in screenshots.
    func setHiddenFromCapture(_ hidden: Bool) {
        panel?.sharingType = hidden ? .none : .readOnly
    }

    func hide() {
        SpeakerNotesModel.shared.stopScrolling()
        setDockedUnderCamera(false, screen: nil)
        panel?.orderOut(nil)
    }

    /// Where the notes sit in camera mode: centered at the top of the screen, right under the built-in camera, so the
    /// eyes stay near the lens while reading.
    static func dockedFrame(on screen: NSScreen?) -> NSRect {
        let vf = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: min(640, vf.width * 0.5), height: min(220, vf.height * 0.25))
        return NSRect(x: vf.midX - size.width / 2, y: vf.maxY - size.height - 8, width: size.width, height: size.height)
    }

    var isDockedUnderCamera: Bool { frameBeforeDocking != nil }

    /// Docks the shown notes under the camera, or puts them back where the user had them. The docked frame is not
    /// saved as the user's own (autosave is off while docked).
    func setDockedUnderCamera(_ docked: Bool, screen: NSScreen?) {
        guard let panel else { return }
        if docked {
            guard frameBeforeDocking == nil, panel.isVisible else { return }
            frameBeforeDocking = panel.frame
            panel.setFrameAutosaveName("")
            panel.setFrame(Self.dockedFrame(on: screen), display: true, animate: true)
        } else if let frame = frameBeforeDocking {
            frameBeforeDocking = nil
            panel.setFrame(frame, display: true, animate: panel.isVisible)
            panel.setFrameAutosaveName(frameKey)
        }
    }
}

struct SpeakerNotesView: View {
    @Bindable var model: SpeakerNotesModel
    @Bindable private var coordinator = RecordingCoordinator.shared

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if model.isPrompting {
                    prompter
                } else {
                    TextEditor(text: $model.text)
                        .font(.system(size: model.fontSize, weight: .medium))
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                        .overlay(alignment: .topLeading) {
                            if model.text.isEmpty {
                                Text("Write what you want to say. Only you see this window; it is not recorded.")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.white.opacity(0.4))
                                    .padding(.horizontal, 17)
                                    .padding(.top, 6)
                                    .allowsHitTesting(false)
                            }
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 22)

            controls
        }
        .background(Color(red: 0.08, green: 0.08, blue: 0.10))
        .onChange(of: coordinator.isRecording) { _, recording in
            if recording && model.scrollsWhileRecording && !model.text.isEmpty {
                model.backToTop()
                model.startScrolling()
            } else if !recording {
                model.stopScrolling()
            }
        }
        .onChange(of: coordinator.isRecordingPaused) { _, paused in
            guard coordinator.isRecording, model.scrollsWhileRecording else { return }
            if paused { model.stopScrolling() } else { model.startScrolling() }
        }
    }

    /// The notes scroll up at `speed`. A reading line a third of the way down marks where to read.
    private var prompter: some View {
        GeometryReader { geo in
            TimelineView(.animation(paused: model.scrollingSince == nil)) { context in
                let offset = model.currentOffset(at: context.date)
                Text(model.text)
                    .font(.system(size: model.fontSize, weight: .semibold))
                    .lineSpacing(model.fontSize * 0.35)
                    .foregroundStyle(.white.opacity(0.95))
                    .frame(width: max(10, geo.size.width - 40), alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(x: 20, y: geo.size.height / 3 - offset)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                    .clipped()
                    .overlay(alignment: .topLeading) {
                        Rectangle()
                            .fill(Color(red: 0.62, green: 0.55, blue: 1.0).opacity(0.7))
                            .frame(width: 4, height: model.fontSize * 1.2)
                            .offset(x: 8, y: geo.size.height / 3)
                    }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if model.scrollingSince == nil { model.startScrolling() } else { model.stopScrolling() }
            }
        }
    }

    private var controls: some View {
        let isScrolling = model.scrollingSince != nil
        return HStack(spacing: 2) {
            controlButton(
                model.isPrompting ? "Edit notes" : "Show as prompter",
                icon: model.isPrompting ? "pencil" : "text.alignleft"
            ) {
                if model.isPrompting {
                    model.stopScrolling()
                    model.isPrompting = false
                } else {
                    model.isPrompting = true
                }
            }
            controlButton(isScrolling ? "Pause scrolling" : "Scroll", badge: "Space".localizedUI, icon: isScrolling ? "pause.fill" : "play.fill", isDisabled: model.text.isEmpty) {
                model.toggleScrolling()
            }
            controlButton("Back to the top", icon: "arrow.up.to.line") { model.backToTop() }

            Divider().frame(height: 18).padding(.horizontal, 6)

            Image(systemName: "hare")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Slider(value: Binding(get: { model.speed }, set: { model.setSpeed($0) }), in: SpeakerNotesModel.speedRange)
                .frame(minWidth: 60, maxWidth: 110)
                .controlSize(.small)
                .accessibilityLabel(Text("Scroll speed"))
                .padding(.trailing, 4)

            Spacer(minLength: 0)

            controlButton("Smaller text", icon: "textformat.size.smaller") {
                model.fontSize = max(SpeakerNotesModel.fontSizeRange.lowerBound, model.fontSize - 2)
            }
            controlButton("Larger text", icon: "textformat.size.larger") {
                model.fontSize = min(SpeakerNotesModel.fontSizeRange.upperBound, model.fontSize + 2)
            }
            controlButton("Scroll from the top when recording starts", icon: "record.circle", isActive: model.scrollsWhileRecording) {
                model.scrollsWhileRecording.toggle()
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 46)
        .background(Color.white.opacity(0.04))
    }

    /// The app's own button: magnet hover and instant, translated tooltip.
    private func controlButton(
        _ tooltip: String,
        badge: String? = nil,
        icon: String,
        isActive: Bool = false,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        InstantTooltipButton(
            tooltip: tooltip,
            shortcutBadge: badge,
            edge: .top,
            isActive: isActive,
            isDisabled: isDisabled,
            size: 34,
            cornerRadius: 7,
            action: action
        ) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isActive ? Color(red: 0.72, green: 0.64, blue: 1.0) : .white.opacity(0.9))
        }
    }
}
