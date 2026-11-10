import SwiftUI

/// Drawn over the large camera-mode preview: thirds to frame yourself with, the camera in use, and the record button.
/// A camera-only recording captures no screen, so the preview can stay up while recording.
struct CameraStageOverlayView: View {
    @Bindable var coordinator: RecordingCoordinator

    private var isIdle: Bool { !coordinator.isRecording && !coordinator.isCountingDown }
    private var hasMicrophone: Bool { coordinator.captureMicrophone && coordinator.selectedMicrophoneDeviceID != nil }

    var body: some View {
        ZStack {
            if isIdle {
                ThirdsGrid()
                    .stroke(Color.white.opacity(0.22), lineWidth: 1)
                    .allowsHitTesting(false)
            }

            VStack(spacing: 0) {
                HStack {
                    Label(coordinator.selectedCameraName ?? String(localized: "Camera"), systemImage: "video.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.45), in: Capsule())
                    Spacer(minLength: 0)
                }
                .padding(12)
                .opacity(isIdle ? 1 : 0)

                Spacer(minLength: 0)

                if isIdle {
                    VStack(spacing: 8) {
                        if !hasMicrophone {
                            Label("No microphone selected. The recording will have no sound.", systemImage: "mic.slash")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(.black.opacity(0.55), in: Capsule())
                        }
                        Button {
                            coordinator.requestStartRecording()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "record.circle")
                                Text("Start recording")
                                    .fontWeight(.semibold)
                            }
                            .font(.system(size: 14))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(Color(red: 0.36, green: 0.22, blue: 0.98), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
                            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(coordinator.selectedCameraDeviceID == nil)
                    }
                    .padding(.bottom, 18)
                }
            }
        }
    }
}

/// Lines at a third of the width and height.
private struct ThirdsGrid: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for i in 1...2 {
            let x = rect.minX + rect.width * CGFloat(i) / 3
            let y = rect.minY + rect.height * CGFloat(i) / 3
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        return path
    }
}
