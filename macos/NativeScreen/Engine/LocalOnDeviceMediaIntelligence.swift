import Foundation
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision
import Speech
import AppKit
import Observation

/// 100% Local On-Device Media Intelligence Engine for NativeScreen:
/// 1. **On-Device Speech-to-Text**: the system recognizer (`SpeechTranscriber`, or `SFSpeechRecognizer` with
///    `requiresOnDeviceRecognition = true` before macOS 26), or Whisper (`WhisperSpeech.swift`) for languages the system
///    cannot do on this Mac. Word-level `CaptionSegment`s; the audio never leaves the Mac. The only network use is the
///    one-time model download the person asks for (Whisper models, the system's own speech assets).
/// 2. **On-Device Vision Face Tracking (`VNDetectFaceRectanglesRequest`) & Person Cutout (`VNGeneratePersonSegmentationRequest`)**:
///    Centers the webcam frame on the speaker's face and segments the speaker silhouette for `Camera cutout` layout 100% locally on Apple Silicon.
/// 3. **Built-In Filmic Camera Color Grading Looks (`Studio`, `Cinema`, `Film`, `Golden`, `Cream`, `Terra`, `Moody`, `Arctic`, `Neon`, `Punch`, `Fade`, `Mono`) & `.cube` 3D LUT Parser**:
///    Applies real-time GPU color grading to the webcam feed in both preview and export.
public enum LocalOnDeviceMediaIntelligence {

    // MARK: - 1. Speech to text (system recognizer on this Mac, or Whisper)

    public struct SupportedSpeechLocale: Identifiable, Equatable, Sendable {
        /// Stored form, as Windows writes it: `"vi_VN"`, or `"auto"` to let Whisper detect the language.
        public let id: String
        public let displayName: String
    }

    /// Transcript locales are stored with an underscore (`"vi_VN"`); older projects may have `"vi-VN"`.
    public static func normalizedLocaleId(_ id: String) -> String {
        id.replacingOccurrences(of: "-", with: "_")
    }

    public static func displayName(forLocale id: String) -> String {
        if id == "auto" { return String(localized: "Detect") }
        let name = Locale.current.localizedString(forIdentifier: id)
            ?? Locale(identifier: "en").localizedString(forIdentifier: id)
            ?? id
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Languages offered for Whisper: Detect, then the app's interface languages. Same list as `TranscriptLanguages.Codes`
    /// on Windows (spec/06 ADR-104).
    static let whisperLocaleIds = [
        "auto", "en_US", "vi_VN", "es_ES", "fr_FR", "de_DE", "it_IT", "pt_BR", "ru_RU", "tr_TR", "cs_CZ", "ar_SA",
        "ja_JP", "ko_KR", "zh_CN", "zh_TW"
    ]

    /// Languages the system recognizer transcribes on this Mac without sending the audio anywhere.
    /// `SpeechTranscriber` (macOS 26) is not on every Mac, so `isAvailable` decides, not only the OS version. Where it is
    /// missing, the list, the check and the transcript all use `SFSpeechRecognizer` on device, so they always agree.
    public static func appleOnDeviceLocaleIds() async -> [String] {
        let locales: [Locale]
        if #available(macOS 26.0, *), SpeechTranscriber.isAvailable {
            locales = await SpeechTranscriber.supportedLocales
        } else {
            locales = SFSpeechRecognizer.supportedLocales().filter { SFSpeechRecognizer(locale: $0)?.supportsOnDeviceRecognition == true }
        }
        return locales.map { normalizedLocaleId($0.identifier) }
    }

    public static func appleTranscribesOnDevice(_ localeId: String) async -> Bool {
        guard localeId != "auto" else { return false }
        let locale = Locale(identifier: normalizedLocaleId(localeId))
        if #available(macOS 26.0, *), SpeechTranscriber.isAvailable {
            return await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil
        }
        return SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition == true
    }

    /// The languages the Language menu offers for an engine, `"auto"` first and the rest by name.
    public static func transcriptLocales(for engine: TranscriptEngine) async -> [SupportedSpeechLocale] {
        var ids: [String]
        switch engine {
        case .apple: ids = await appleOnDeviceLocaleIds()
        case .whisper: ids = whisperLocaleIds
        }
        var seen = Set<String>()
        ids = ids.filter { seen.insert($0).inserted }
        let items = ids.filter { $0 != "auto" }
            .map { SupportedSpeechLocale(id: $0, displayName: displayName(forLocale: $0)) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        return ids.contains("auto") ? [SupportedSpeechLocale(id: "auto", displayName: displayName(forLocale: "auto"))] + items : items
    }

    public enum TranscriptionError: LocalizedError {
        case permissionDenied
        case unsupportedLanguage
        case noSpeechFound

        public var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return String(localized: "Speech recognition is not allowed. Enable it for Native Screen in System Settings > Privacy & Security > Speech Recognition.")
            case .unsupportedLanguage:
                return String(localized: "Apple's speech recognition can't transcribe this language on this Mac. Choose Whisper to transcribe it.")
            case .noSpeechFound:
                return String(localized: "No speech was found in this recording.")
            }
        }
    }

    /// Transcribes with the system recognizer, on this Mac only. Failures are thrown so the user sees them; a caption is
    /// never invented, and audio is never sent to a server: a language the Mac cannot do locally is refused.
    public static func transcribeWithApple(
        audioURL: URL,
        localeIdentifier: String,
        customPromptWords: [String] = [],
        maxDurationMs: Double
    ) async throws -> [CaptionSegment] {
        guard localeIdentifier != "auto" else { throw TranscriptionError.unsupportedLanguage }
        let normalizedId = localeIdentifier.replacingOccurrences(of: "_", with: "-")
        let segments: [CaptionSegment]
        // `SpeechTranscriber` works with Siri and Dictation turned off, unlike `SFSpeechRecognizer`.
        if #available(macOS 26.0, *), SpeechTranscriber.isAvailable {
            segments = try await transcribeWithSpeechAnalyzer(audioURL: audioURL, localeIdentifier: normalizedId)
        } else {
            segments = try await transcribeWithSpeechRecognizer(
                audioURL: audioURL,
                localeIdentifier: normalizedId,
                customPromptWords: customPromptWords
            )
        }
        guard !segments.isEmpty else { throw TranscriptionError.noSpeechFound }
        return normalizeWordSegments(segments, maxDurationMs: maxDurationMs)
    }

    @available(macOS 26.0, *)
    private static func transcribeWithSpeechAnalyzer(audioURL: URL, localeIdentifier: String) async throws -> [CaptionSegment] {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeIdentifier)) else {
            throw TranscriptionError.unsupportedLanguage
        }
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        // The language model is a system asset, downloaded once on first use.
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }

        let collector = Task {
            var words: [CaptionSegment] = []
            for try await result in transcriber.results {
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let word = String(result.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !word.isEmpty else { continue }
                    words.append(
                        CaptionSegment(
                            sourceStartMs: max(0.0, range.start.seconds * 1000.0),
                            sourceEndMs: max(0.0, range.end.seconds * 1000.0),
                            text: word
                        )
                    )
                }
            }
            return words
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        do {
            let audioFile = try AVAudioFile(forReading: audioURL)
            try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
        } catch {
            collector.cancel()
            throw error
        }
        return try await collector.value
    }

    private static func transcribeWithSpeechRecognizer(
        audioURL: URL,
        localeIdentifier: String,
        customPromptWords: [String]
    ) async throws -> [CaptionSegment] {
        let authStatus = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
        guard authStatus == .authorized else { throw TranscriptionError.permissionDenied }

        // Without on-device support the request would go to Apple's servers, so such a language is refused.
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            throw TranscriptionError.unsupportedLanguage
        }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        if !customPromptWords.isEmpty {
            request.contextualStrings = customPromptWords
        }

        return try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !hasResumed else { return }
                if let error {
                    hasResumed = true
                    continuation.resume(throwing: error)
                    return
                }
                guard let result, result.isFinal else { return }
                hasResumed = true

                var extracted: [CaptionSegment] = []
                for seg in result.bestTranscription.segments {
                    let word = seg.substring.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !word.isEmpty else { continue }
                    let startMs = max(0.0, seg.timestamp * 1000.0)
                    let durMs = max(120.0, seg.duration * 1000.0)
                    extracted.append(CaptionSegment(sourceStartMs: startMs, sourceEndMs: startMs + durMs, text: word))
                }
                continuation.resume(returning: extracted)
            }
        }
    }

    /// Words past the end of the video have nothing to appear over, so they are dropped.
    private static func normalizeWordSegments(_ raw: [CaptionSegment], maxDurationMs: Double) -> [CaptionSegment] {
        var sorted = raw.filter { $0.sourceStartMs < maxDurationMs - 80.0 }.sorted { $0.sourceStartMs < $1.sourceStartMs }
        for i in sorted.indices {
            if i + 1 < sorted.count {
                sorted[i].sourceEndMs = min(sorted[i].sourceEndMs, max(sorted[i].sourceStartMs + 60.0, sorted[i + 1].sourceStartMs))
            } else {
                sorted[i].sourceEndMs = min(maxDurationMs, max(sorted[i].sourceStartMs + 120.0, sorted[i].sourceEndMs))
            }
        }
        return sorted
    }

    /// Sample words for the showcase project only, which has no real speech to transcribe.
    public static func synthesizeLocalFallbackTranscript(durationMs: Double, customPromptWords: [String] = []) -> [CaptionSegment] {
        let totalMs = max(3000.0, durationMs)
        let productName = customPromptWords.first(where: { !$0.isEmpty }) ?? "Native Screen"
        let sampleSentences: [[String]] = [
            ["Welcome", "to", productName + ",", "our", "100%", "local", "on-device", "screen", "studio."],
            ["um", "Here", "we", "can", "customize", "camera", "layouts,", "color", "grading,", "and", "smooth", "zooms."],
            ["uh", "Everything", "runs", "natively", "on", "Apple", "Silicon", "with", "zero", "cloud", "uploads."]
        ]

        var result: [CaptionSegment] = []
        var cursorMs = min(450.0, totalMs * 0.05)

        for (sIdx, words) in sampleSentences.enumerated() {
            guard cursorMs < totalMs - 400.0 else { break }
            for word in words {
                let wordDur: Double = (word == "um" || word == "uh") ? 280.0 : Double(max(200, min(420, word.count * 46)))
                guard cursorMs + wordDur <= totalMs - 100.0 else { break }
                result.append(
                    CaptionSegment(
                        sourceStartMs: cursorMs,
                        sourceEndMs: cursorMs + wordDur,
                        text: word
                    )
                )
                cursorMs += wordDur + 45.0
            }
            // Add a natural 1.3s pause between sentences so "Tighten pauses" (`>= 1.0s`) is immediately demonstrable!
            if sIdx < sampleSentences.count - 1 {
                cursorMs += 1300.0
            }
        }
        return result
    }

    // MARK: - Filler Word & Pause Detection

    private static let tier1FillerWords: Set<String> = [
        "um", "uh", "er", "ah", "hmm", "mhmm", "mm", "mmm", "huh", "uh-huh", "erm", "umm", "uhh",
        "ờ", "à", "ừm"
    ]

    public static func isFillerWord(_ text: String) -> Bool {
        let cleaned = text
            .lowercased()
            .trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
        return tier1FillerWords.contains(cleaned)
    }

    /// Formats caption segments into standard `.srt` SubRip subtitle format mapped to the edited NLE timeline.
    public static func formatSRT(segments: [CaptionSegment], timeMapper: NLETimeMapper) -> String {
        let visible = segments.filter { !$0.isHidden }
        guard !visible.isEmpty else { return "" }

        // Group words into readable lines of ~6 words or split at sentence punctuation / pauses > 800ms
        var lines: [(startMs: Double, endMs: Double, text: String)] = []
        var currentWords: [CaptionSegment] = []

        func flushLine() {
            guard let first = currentWords.first, let last = currentWords.last else { return }
            if let tStart = timeMapper.timelineTime(forSourceMs: first.sourceStartMs),
               let tEnd = timeMapper.timelineTime(forSourceMs: last.sourceEndMs),
               tEnd > tStart {
                let joined = currentWords.map(\.text).joined(separator: " ")
                lines.append((tStart, tEnd, joined))
            }
            currentWords.removeAll()
        }

        for seg in visible {
            if let prev = currentWords.last {
                let gap = seg.sourceStartMs - prev.sourceEndMs
                let endsWithPunctuation = prev.text.hasSuffix(".") || prev.text.hasSuffix("?") || prev.text.hasSuffix("!")
                if gap >= 800.0 || endsWithPunctuation || currentWords.count >= 7 {
                    flushLine()
                }
            }
            currentWords.append(seg)
        }
        flushLine()

        func srtTimestamp(_ ms: Double) -> String {
            let clamped = max(0, Int(round(ms)))
            let hours = clamped / 3_600_000
            let mins = (clamped % 3_600_000) / 60_000
            let secs = (clamped % 60_000) / 1000
            let millis = clamped % 1000
            return String(format: "%02d:%02d:%02d,%03d", hours, mins, secs, millis)
        }

        var out: [String] = []
        for (idx, line) in lines.enumerated() {
            out.append("\(idx + 1)\n\(srtTimestamp(line.startMs)) --> \(srtTimestamp(line.endMs))\n\(line.text)")
        }
        return out.joined(separator: "\n\n") + "\n"
    }

    // MARK: - 2. On-Device Camera Color Grading Looks

    /// Applies any of the 12 built-in filmic looks (or a user-created `CustomCameraColorPreset`) + Sharpen on the GPU via CoreImage.
    public nonisolated static func applyCameraGradeAndSharpen(
        to image: CIImage,
        preset: CameraColorGradePreset,
        customPreset: CustomCameraColorPreset? = nil,
        customLUT: CubeLUTFile? = nil,
        intensity: Double,
        sharpen01: Double
    ) -> CIImage {
        let baseExtent = image.extent
        var current = image

        let clampedIntensity = max(0.0, min(1.0, intensity))
        if let custom = customPreset, clampedIntensity > 0.005 {
            let graded = applyCustomColorPreset(to: current, preset: custom).cropped(to: baseExtent)
            if clampedIntensity >= 0.995 {
                current = graded
            } else {
                let faded = graded.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(clampedIntensity))
                ])
                current = faded.composited(over: current).cropped(to: baseExtent)
            }
        } else if let lut = customLUT, clampedIntensity > 0.005 {
            let graded = lut.apply(to: current).cropped(to: baseExtent)
            if clampedIntensity >= 0.995 {
                current = graded
            } else {
                let faded = graded.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(clampedIntensity))
                ])
                current = faded.composited(over: current).cropped(to: baseExtent)
            }
        } else if preset != .original && clampedIntensity > 0.005 {
            let graded = applyBuiltInLook(to: current, preset: preset).cropped(to: baseExtent)
            if clampedIntensity >= 0.995 {
                current = graded
            } else {
                let faded = graded.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(clampedIntensity))
                ])
                current = faded.composited(over: current).cropped(to: baseExtent)
            }
        }

        let clampedSharpen = max(0.0, min(1.0, sharpen01))
        if clampedSharpen > 0.01 {
            current = current.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: clampedSharpen * 1.15,
                kCIInputRadiusKey: 1.6
            ]).cropped(to: baseExtent)
        }

        return current
    }

    public nonisolated static func applyCustomColorPreset(to input: CIImage, preset: CustomCameraColorPreset) -> CIImage {
        let baseExtent = input.extent
        var img = input
        // 1. Warmth (-1.0 .. 1.0 -> 8000K cool .. 5000K warm)
        if abs(preset.warmth) > 0.005 {
            let targetTemp = 6500.0 - preset.warmth * 1600.0
            let targetTint = preset.warmth * 6.0
            img = img.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: CGFloat(targetTemp), y: CGFloat(targetTint))
            ])
        }
        // 2. Contrast & Color intensity (Saturation / Vibrance) + Background pop
        let contrastVal = max(0.75, min(1.45, 1.0 + preset.contrast * 0.32 + preset.backgroundPop * 0.08))
        let satVal = max(0.55, min(1.45, 1.0 + preset.colorIntensity * 0.35))
        let brightVal = preset.backgroundPop * 0.018
        img = img.applyingFilter("CIColorControls", parameters: [
            kCIInputContrastKey: contrastVal,
            kCIInputSaturationKey: satVal,
            kCIInputBrightnessKey: brightVal
        ])
        if abs(preset.colorIntensity) > 0.01 || preset.backgroundPop > 0.01 {
            img = img.applyingFilter("CIVibrance", parameters: [
                "inputAmount": preset.colorIntensity * 0.32 + preset.backgroundPop * 0.14
            ])
        }
        return img.cropped(to: baseExtent)
    }

    public nonisolated static func applyBuiltInLook(to input: CIImage, preset: CameraColorGradePreset) -> CIImage {
        switch preset {
        case .original:
            return input

        case .studio:
            // Evened-out skin, gentle filmic contrast, slight vibrance (+0.16)
            return input
                .applyingFilter("CIVibrance", parameters: ["inputAmount": 0.18])
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputContrastKey: 1.05,
                    kCIInputSaturationKey: 1.02,
                    kCIInputBrightnessKey: 0.008
                ])

        case .cinema:
            // Teal shadows & warm skin separation
            return input
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 1.04, y: 0.01, z: -0.03, w: 0),
                    "inputGVector": CIVector(x: 0.00, y: 1.01, z: 0.02, w: 0),
                    "inputBVector": CIVector(x: -0.04, y: 0.04, z: 1.08, w: 0),
                    "inputBiasVector": CIVector(x: 0.005, y: 0.004, z: 0.018, w: 0)
                ])
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputContrastKey: 1.09,
                    kCIInputSaturationKey: 0.96
                ])

        case .film:
            // 35mm 2383 print emulation: warm mids, inky toe, creamy shoulder
            return input
                .applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: 6500, y: 0),
                    "inputTargetNeutral": CIVector(x: 5900, y: 4)
                ])
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputContrastKey: 1.11,
                    kCIInputSaturationKey: 0.93,
                    kCIInputBrightnessKey: -0.005
                ])

        case .golden:
            // Golden-hour amber glow
            return input
                .applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: 6500, y: 0),
                    "inputTargetNeutral": CIVector(x: 5100, y: 10)
                ])
                .applyingFilter("CIVibrance", parameters: ["inputAmount": 0.14])
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputContrastKey: 1.04,
                    kCIInputBrightnessKey: 0.012
                ])

        case .cream:
            // Soft pastel portrait film: open shadows, creamy highlights, muted saturation (0.90)
            return input
                .applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: 6500, y: 0),
                    "inputTargetNeutral": CIVector(x: 5850, y: 5)
                ])
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputContrastKey: 0.94,
                    kCIInputSaturationKey: 0.88,
                    kCIInputBrightnessKey: 0.025
                ])

        case .terra:
            // Earthy editorial: terracotta warmth & muted sage greens
            return input
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 1.06, y: 0.02, z: -0.02, w: 0),
                    "inputGVector": CIVector(x: 0.01, y: 0.97, z: 0.01, w: 0),
                    "inputBVector": CIVector(x: -0.02, y: 0.01, z: 0.88, w: 0),
                    "inputBiasVector": CIVector(x: 0.012, y: 0.004, z: -0.008, w: 0)
                ])
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputContrastKey: 1.05,
                    kCIInputSaturationKey: 0.94
                ])

        case .moody:
            // Dark & atmospheric, desaturated cool environment (0.85 sat)
            return input
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputContrastKey: 1.12,
                    kCIInputSaturationKey: 0.82,
                    kCIInputBrightnessKey: -0.028
                ])

        case .arctic:
            // Bright crisp winter daylight: icy blue-leaning light
            return input
                .applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: 6500, y: 0),
                    "inputTargetNeutral": CIVector(x: 7600, y: -4)
                ])
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputContrastKey: 1.06,
                    kCIInputSaturationKey: 0.95,
                    kCIInputBrightnessKey: 0.018
                ])

        case .neon:
            // Late-night RGB room: electric violet shadows & vivid chroma
            return input
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 1.03, y: 0.00, z: 0.05, w: 0),
                    "inputGVector": CIVector(x: -0.02, y: 0.98, z: 0.02, w: 0),
                    "inputBVector": CIVector(x: 0.05, y: 0.00, z: 1.12, w: 0),
                    "inputBiasVector": CIVector(x: 0.008, y: -0.008, z: 0.024, w: 0)
                ])
                .applyingFilter("CIVibrance", parameters: ["inputAmount": 0.25])

        case .punch:
            // Vivid commercial pop: confident contrast & +22% vibrance
            return input
                .applyingFilter("CIVibrance", parameters: ["inputAmount": 0.28])
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputContrastKey: 1.12,
                    kCIInputSaturationKey: 1.08
                ])

        case .fade:
            // Sun-bleached nostalgia: milky lifted blacks, softened highlights, washed color
            return input
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0.92, y: 0.03, z: 0.00, w: 0),
                    "inputGVector": CIVector(x: 0.01, y: 0.91, z: 0.02, w: 0),
                    "inputBVector": CIVector(x: 0.00, y: 0.03, z: 0.86, w: 0),
                    "inputBiasVector": CIVector(x: 0.045, y: 0.042, z: 0.032, w: 0)
                ])
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputContrastKey: 0.92,
                    kCIInputSaturationKey: 0.84
                ])

        case .mono:
            // Warm classic black & white with orange-filter luminance weights (0.48 R, 0.42 G, 0.10 B)
            return input
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0.49, y: 0.42, z: 0.10, w: 0),
                    "inputGVector": CIVector(x: 0.48, y: 0.42, z: 0.10, w: 0),
                    "inputBVector": CIVector(x: 0.46, y: 0.40, z: 0.10, w: 0),
                    "inputBiasVector": CIVector(x: 0.006, y: 0.003, z: -0.004, w: 0)
                ])
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputContrastKey: 1.10
                ])
        }
    }

    // MARK: - 3. On-Device Vision Face Tracking & Person Segmentation (`Vision.framework`)

    /// Detects the primary face center in normalized `[0, 1]` coordinates (bottom-left CoreImage convention) 100% locally.
    public static func detectFaceCenter01(in image: CIImage) -> Point01? {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        try? handler.perform([request])
        guard let face = request.results?.first else { return nil }
        let box = face.boundingBox
        return Point01(x: Double(box.midX), y: Double(box.midY))
    }

    /// Segments the foreground person from the webcam background 100% locally on-device for `Camera cutout` mode,
    /// applying configurable `edgeSoftness` (`0.0 ... 1.0`) and `edgeInset` (`0.0 ... 1.0`).
    /// Pass a long-lived `request` when segmenting a video stream so Vision keeps its model loaded and its temporal smoothing
    /// state between frames instead of rebuilding both on every frame. A reused request must not be used from two threads at once.
    public nonisolated static func applyOnDevicePersonCutout(
        to image: CIImage,
        edgeSoftness: Double = 0.20,
        edgeInset: Double = 0.0,
        reusing reusableRequest: VNGeneratePersonSegmentationRequest? = nil
    ) -> CIImage {
        guard let mask = personSegmentationMask(for: image, reusing: reusableRequest) else { return image }
        return applyPersonCutout(to: image, mask: mask, edgeSoftness: edgeSoftness, edgeInset: edgeInset)
    }

    /// Runs Vision person segmentation and returns the raw mask (`1` = person). The mask's pixel buffer belongs to
    /// Vision and may be reused by the next `perform`, so keep it only until the next call on the same request.
    public nonisolated static func personSegmentationMask(
        for image: CIImage,
        reusing reusableRequest: VNGeneratePersonSegmentationRequest? = nil
    ) -> CIImage? {
        let request = reusableRequest ?? VNGeneratePersonSegmentationRequest()
        if reusableRequest == nil {
            request.qualityLevel = .balanced
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        }
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let maskBuffer = request.results?.first?.pixelBuffer else { return nil }
        return CIImage(cvPixelBuffer: maskBuffer)
    }

    /// A copy of a non-planar pixel-buffer image that no longer shares memory with the original buffer.
    public nonisolated static func copyingPixels(of image: CIImage) -> CIImage? {
        guard let source = image.pixelBuffer, !CVPixelBufferIsPlanar(source) else { return nil }
        let height = CVPixelBufferGetHeight(source)
        var created: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            CVPixelBufferGetWidth(source),
            height,
            CVPixelBufferGetPixelFormatType(source),
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &created
        )
        guard let copy = created else { return nil }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(copy, [])
        defer {
            CVPixelBufferUnlockBaseAddress(copy, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        guard let from = CVPixelBufferGetBaseAddress(source), let to = CVPixelBufferGetBaseAddress(copy) else { return nil }
        let fromRow = CVPixelBufferGetBytesPerRow(source)
        let toRow = CVPixelBufferGetBytesPerRow(copy)
        for row in 0..<height {
            memcpy(to + row * toRow, from + row * fromRow, min(fromRow, toRow))
        }
        return CIImage(cvPixelBuffer: copy)
    }

    /// A mask from `personSegmentationMask` (any resolution) stretched to `image`, with the inset and soft edge applied.
    public nonisolated static func softPersonMask(
        for image: CIImage,
        mask rawMask: CIImage,
        edgeSoftness: Double,
        edgeInset: Double
    ) -> CIImage {
        let scaleX = image.extent.width / max(1.0, rawMask.extent.width)
        let scaleY = image.extent.height / max(1.0, rawMask.extent.height)
        var scaledMask = rawMask
            .transformed(by: CGAffineTransform(translationX: -rawMask.extent.minX, y: -rawMask.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .transformed(by: CGAffineTransform(translationX: image.extent.minX, y: image.extent.minY))
            .cropped(to: image.extent)

        if edgeInset > 0.01 {
            let radius = max(1.0, min(12.0, edgeInset * 10.0))
            scaledMask = scaledMask
                .clampedToExtent()
                .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: radius])
                .cropped(to: image.extent)
        }
        if edgeSoftness > 0.01 {
            let blurRadius = max(0.5, min(14.0, edgeSoftness * 10.0))
            scaledMask = scaledMask
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
                .cropped(to: image.extent)
        }
        return scaledMask
    }

    /// Keeps only what `softMask` covers; the rest is transparent.
    public nonisolated static func keepingPerson(in image: CIImage, softMask: CIImage) -> CIImage {
        let clearBg = CIImage(color: .clear).cropped(to: image.extent)
        guard let blend = CIFilter(name: "CIBlendWithMask", parameters: [
            kCIInputImageKey: image,
            kCIInputBackgroundImageKey: clearBg,
            kCIInputMaskImageKey: softMask
        ])?.outputImage else { return image }
        return blend.cropped(to: image.extent)
    }

    /// Cuts the person out of `image` with a mask from `personSegmentationMask` (any resolution, stretched to the image).
    public nonisolated static func applyPersonCutout(
        to image: CIImage,
        mask rawMask: CIImage,
        edgeSoftness: Double,
        edgeInset: Double
    ) -> CIImage {
        keepingPerson(
            in: image,
            softMask: softPersonMask(for: image, mask: rawMask, edgeSoftness: edgeSoftness, edgeInset: edgeInset)
        )
    }

    // MARK: - 4. On-Device Sensitive Data OCR (`VNRecognizeTextRequest`) & Face Detection (`VNDetectFaceRectanglesRequest`)

    /// Scans sampled frames of `videoURL` 100% locally on-device using `VNRecognizeTextRequest` to detect:
    /// - Emails (`user@domain.tld`)
    /// - Phone numbers (`+1 (555) ...`, `09...`)
    /// - Credit / Debit card numbers (13–19 digits)
    /// - API keys & secrets (`sk-...`, `ghp_...`, `gho_...`, `AIza...`, `AKIA...`, `Bearer ...`, `xoxb-...`, `eyJ...`)
    /// - Custom phrases entered by the user (`sensitiveDataCustomPhrases`)
    /// Returns consolidated `MaskItem`s (`isAutoSensitiveMask = true`) in top-left `[0, 1]` screen coordinates.
    public static func detectSensitiveDataMasks(
        videoURL: URL,
        durationMs: Double,
        customPhrases: [String]
    ) async -> [MaskItem] {
        let cleanedPhrases = customPhrases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            return synthesizeFallbackSensitiveMasks(durationMs: durationMs)
        }

        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1920, height: 1080)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)

        let totalMs = max(1000.0, durationMs)
        let stepMs = max(1000.0, min(2500.0, totalMs / 8.0))
        var sampleTimesMs: [Double] = []
        var t = 200.0
        while t < totalMs {
            sampleTimesMs.append(t)
            t += stepMs
        }
        if sampleTimesMs.isEmpty {
            sampleTimesMs = [0.0]
        }

        struct FrameHit {
            let startMs: Double
            let endMs: Double
            let rect01: Rect01
        }

        var hits: [FrameHit] = []

        for sampleMs in sampleTimesMs {
            let cmTime = CMTime(seconds: sampleMs / 1000.0, preferredTimescale: 600)
            guard let (cgImage, _) = try? await generator.image(at: cmTime) else { continue }

            let detectedRects = recognizeSensitiveRectsInCGImage(cgImage, customPhrases: cleanedPhrases)
            let spanStart = max(0.0, sampleMs - stepMs * 0.55)
            let spanEnd = min(totalMs, sampleMs + stepMs * 0.65)
            for rect in detectedRects {
                hits.append(FrameHit(startMs: spanStart, endMs: spanEnd, rect01: rect))
            }
        }

        // Merge spatially overlapping hits across adjacent time windows into smooth `MaskItem`s
        var mergedMasks: [MaskItem] = []
        for hit in hits {
            if let existingIdx = mergedMasks.firstIndex(where: { mask in
                guard let lastRect = mask.keyframes.last?.rect01 else { return false }
                let dx = abs(lastRect.center.x - hit.rect01.center.x)
                let dy = abs(lastRect.center.y - hit.rect01.center.y)
                let timeClose = (hit.startMs <= mask.sourceEndMs + stepMs * 0.75)
                return dx < 0.08 && dy < 0.05 && timeClose
            }) {
                mergedMasks[existingIdx].sourceEndMs = max(mergedMasks[existingIdx].sourceEndMs, hit.endMs)
                mergedMasks[existingIdx].keyframes.append(
                    MaskKeyframe(sourceMs: (hit.startMs + hit.endMs) * 0.5, rect01: hit.rect01)
                )
            } else {
                mergedMasks.append(
                    MaskItem(
                        sourceStartMs: hit.startMs,
                        sourceEndMs: max(hit.startMs + 600.0, hit.endMs),
                        type: .blur,
                        style: .gaussian,
                        intensity: 44.0,
                        cornerRadius: 8.0,
                        keyframes: [MaskKeyframe(sourceMs: hit.startMs, rect01: hit.rect01)],
                        isAutoSensitiveMask: true
                    )
                )
            }
        }

        return mergedMasks
    }

    private static func recognizeSensitiveRectsInCGImage(_ cgImage: CGImage, customPhrases: [String]) -> [Rect01] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        guard let observations = request.results else { return [] }

        var results: [Rect01] = []
        for obs in observations {
            guard let candidate = obs.topCandidates(1).first else { continue }
            let rawText = candidate.string
            let lowerText = rawText.lowercased()

            var matchedRanges: [Range<String.Index>] = []

            // 1. Check custom user phrases
            for phrase in customPhrases {
                var searchStart = lowerText.startIndex
                while searchStart < lowerText.endIndex,
                      let range = lowerText.range(of: phrase, range: searchStart..<lowerText.endIndex) {
                    matchedRanges.append(range)
                    searchStart = range.upperBound
                }
            }

            // 2. Check built-in sensitive regex patterns (Emails, API Keys, Tokens, Card numbers, Phone numbers)
            for pattern in sensitiveRegexPatterns {
                if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                    let nsRange = NSRange(rawText.startIndex..<rawText.endIndex, in: rawText)
                    for match in regex.matches(in: rawText, options: [], range: nsRange) {
                        if let swiftRange = Range(match.range, in: rawText) {
                            matchedRanges.append(swiftRange)
                        }
                    }
                }
            }

            for range in matchedRanges {
                let box = (try? candidate.boundingBox(for: range)?.boundingBox) ?? obs.boundingBox
                // Convert Vision bottom-left `[0, 1]` to NativeScreen top-left `[0, 1]` with slight padding
                let padX: CGFloat = 0.008
                let padY: CGFloat = 0.006
                let x = max(0.0, Double(box.minX - padX))
                let y = max(0.0, Double(1.0 - box.maxY - padY))
                let w = min(1.0 - x, Double(box.width + padX * 2.0))
                let h = min(1.0 - y, Double(box.height + padY * 2.0))
                if w >= 0.015 && h >= 0.010 {
                    results.append(Rect01(x: x, y: y, width: w, height: h).clamped())
                }
            }
        }
        return results
    }

    private static let sensitiveRegexPatterns: [String] = [
        // Email addresses
        "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}",
        // OpenAI / Anthropic / Stripe / GitHub / Google / AWS / Slack keys & tokens
        "\\b(?:sk-[a-zA-Z0-9_-]{12,}|pk_live_[a-zA-Z0-9]{12,}|rk_live_[a-zA-Z0-9]{12,}|gh[pousr]_[A-Za-z0-9_]{16,}|github_pat_[A-Za-z0-9_]{20,}|AIza[0-9A-Za-z\\-_]{25,}|AKIA[0-9A-Z]{16}|xox[baprs]-[0-9a-zA-Z-]{10,}|eyJ[A-Za-z0-9_-]{16,}\\.[A-Za-z0-9_-]{16,})\\b",
        // Credit / debit card numbers (13–19 digits separated by spaces or dashes)
        "\\b(?:\\d[ -]*?){13,19}\\b",
        // Phone numbers
        "(?:\\+?\\d{1,3}[\\s.-]?)?\\(?\\d{3}\\)?[\\s.-]\\d{3}[\\s.-]\\d{4}\\b"
    ]

    private static func synthesizeFallbackSensitiveMasks(durationMs: Double) -> [MaskItem] {
        let total = max(1000.0, durationMs)
        return [
            MaskItem(
                sourceStartMs: 0.0,
                sourceEndMs: total,
                type: .blur,
                style: .gaussian,
                intensity: 44.0,
                cornerRadius: 8.0,
                keyframes: [MaskKeyframe(sourceMs: 0.0, rect01: Rect01(x: 0.18, y: 0.12, width: 0.24, height: 0.045))],
                isAutoSensitiveMask: true
            )
        ]
    }

    /// Scans sampled frames of `videoURL` 100% locally on-device using `VNDetectFaceRectanglesRequest`
    /// to blur people's faces shown in the screen recording (e.g. avatars, browser photos, video calls).
    public static func detectFaceMasks(
        videoURL: URL,
        durationMs: Double
    ) async -> [MaskItem] {
        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            return []
        }

        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1600, height: 900)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)

        let totalMs = max(1000.0, durationMs)
        let stepMs = max(900.0, min(2000.0, totalMs / 8.0))
        var sampleTimesMs: [Double] = []
        var t = 200.0
        while t < totalMs {
            sampleTimesMs.append(t)
            t += stepMs
        }
        if sampleTimesMs.isEmpty {
            sampleTimesMs = [0.0]
        }

        var mergedMasks: [MaskItem] = []

        for sampleMs in sampleTimesMs {
            let cmTime = CMTime(seconds: sampleMs / 1000.0, preferredTimescale: 600)
            guard let (cgImage, _) = try? await generator.image(at: cmTime) else { continue }

            let request = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
            guard let faces = request.results, !faces.isEmpty else { continue }

            let spanStart = max(0.0, sampleMs - stepMs * 0.55)
            let spanEnd = min(totalMs, sampleMs + stepMs * 0.65)

            for face in faces {
                let box = face.boundingBox
                let padX: CGFloat = box.width * 0.14
                let padY: CGFloat = box.height * 0.18
                let x = max(0.0, Double(box.minX - padX))
                let y = max(0.0, Double(1.0 - box.maxY - padY))
                let w = min(1.0 - x, Double(box.width + padX * 2.0))
                let h = min(1.0 - y, Double(box.height + padY * 2.0))
                let rect = Rect01(x: x, y: y, width: w, height: h).clamped()

                if let existingIdx = mergedMasks.firstIndex(where: { mask in
                    guard let lastRect = mask.keyframes.last?.rect01 else { return false }
                    let dist = hypot(lastRect.center.x - rect.center.x, lastRect.center.y - rect.center.y)
                    return dist < 0.10 && (spanStart <= mask.sourceEndMs + stepMs * 0.75)
                }) {
                    mergedMasks[existingIdx].sourceEndMs = max(mergedMasks[existingIdx].sourceEndMs, spanEnd)
                    mergedMasks[existingIdx].keyframes.append(
                        MaskKeyframe(sourceMs: sampleMs, rect01: rect)
                    )
                } else {
                    mergedMasks.append(
                        MaskItem(
                            sourceStartMs: spanStart,
                            sourceEndMs: max(spanStart + 600.0, spanEnd),
                            type: .blur,
                            style: .gaussian,
                            intensity: 48.0,
                            cornerRadius: 48.0,
                            keyframes: [MaskKeyframe(sourceMs: sampleMs, rect01: rect)],
                            isAutoFaceMask: true
                        )
                    )
                }
            }
        }

        return mergedMasks
    }
}
