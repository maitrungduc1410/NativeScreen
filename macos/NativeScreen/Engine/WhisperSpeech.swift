import AVFoundation
import Foundation
import Observation
import whisper

// Captions with whisper.cpp for languages the system speech recognizer cannot do on this Mac. Same models, file names and
// tiers as Windows (`WhisperTranscriber.cs`), so a project's `whisperModelTier` means the same thing on both.

/// Which speech engine makes the transcript, chosen by the person. Stored in `captions.localModelVariant`.
public enum TranscriptEngine: String, CaseIterable, Identifiable, Sendable {
    case apple
    case whisper

    public var id: String { rawValue }

    /// `"system"` was written before the engine could be chosen (and is what Windows writes), so it means Apple.
    public init(storedValue: String) {
        self = storedValue == TranscriptEngine.whisper.rawValue ? .whisper : .apple
    }

    /// An English key; the inspector's pills translate it with `localizedUI`.
    public var label: String {
        switch self {
        case .apple: return "Apple"
        case .whisper: return "Whisper"
        }
    }
}

public enum WhisperModelTier: String, CaseIterable, Identifiable, Sendable {
    case base
    case small
    case medium

    public var id: String { rawValue }

    /// Unknown values fall back to Small, like `WhisperModel.ForTier` on Windows.
    public init(storedValue: String) {
        self = WhisperModelTier(rawValue: storedValue) ?? .small
    }

    /// The model's name, an English key the inspector translates with `localizedUI`.
    public var label: String {
        switch self {
        case .base: return "Base"
        case .small: return "Small"
        case .medium: return "Medium"
        }
    }

    public var fileName: String { "ggml-\(rawValue).bin" }

    /// Exact file sizes. A file of any other size is a partial or broken download.
    public var byteCount: Int64 {
        switch self {
        case .base: return 147_951_465
        case .small: return 487_601_967
        case .medium: return 1_533_774_781
        }
    }

    public var sizeText: String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    public var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")!
    }

    public var descriptionText: String {
        switch self {
        case .base: return String(localized: "Fastest, but makes more mistakes.")
        case .small: return String(localized: "Good results in most cases. About 2.5 times slower than Base.")
        case .medium: return String(localized: "The most accurate. About 8 times slower than Base and needs 5 GB of memory.")
        }
    }

    /// In Application Support, which is inside the app's container in the Mac App Store build.
    public nonisolated var localURL: URL {
        WhisperModelStore.modelsDirectoryURL.appendingPathComponent(fileName)
    }

    public nonisolated var isInstalled: Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?.int64Value
        return size == byteCount
    }
}

/// The Whisper models of the whole app, so every editor window shows the same download. One download per tier at a time.
@Observable
@MainActor
public final class WhisperModelStore {
    public static let shared = WhisperModelStore()

    /// Share done (0...1) of each running download.
    public private(set) var progress: [WhisperModelTier: Double] = [:]
    /// Why the last download of a tier failed, until it is tried again.
    public private(set) var failure: [WhisperModelTier: String] = [:]
    /// Transcripts reading each model now. A model in use cannot be deleted.
    public private(set) var inUse: [WhisperModelTier: Int] = [:]
    /// Bumped whenever a model appears or disappears on disk, so views reading `isInstalled(_:)` refresh.
    public private(set) var revision = 0

    /// The model chosen, downloaded or used most recently, in any project.
    public private(set) var lastUsed: WhisperModelTier?

    @ObservationIgnored private var running: [WhisperModelTier: Task<Bool, Never>] = [:]
    private static let lastUsedKey = "NativeScreen.LastWhisperModelTier"

    private init() {
        lastUsed = UserDefaults.standard.string(forKey: Self.lastUsedKey).flatMap(WhisperModelTier.init(rawValue:))
    }

    public func noteUsed(_ tier: WhisperModelTier) {
        lastUsed = tier
        UserDefaults.standard.set(tier.rawValue, forKey: Self.lastUsedKey)
    }

    /// The model a project without a transcript opens with: the only model on this Mac, or the most recently used of
    /// several. Nil when none is downloaded, so the project keeps its own.
    public func preferredTier() -> WhisperModelTier? {
        let installed = WhisperModelTier.allCases.filter(\.isInstalled)
        if installed.count == 1 { return installed[0] }
        if let lastUsed, installed.contains(lastUsed) { return lastUsed }
        return installed.first
    }

    public nonisolated static var modelsDirectoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("NativeScreen/WhisperModels", isDirectory: true)
    }

    public func isInstalled(_ tier: WhisperModelTier) -> Bool {
        _ = revision
        return tier.isInstalled
    }

    public func isDownloading(_ tier: WhisperModelTier) -> Bool { running[tier] != nil }

    /// Downloads the model, or joins its running download. True once the model is on this Mac.
    /// Only call this after the person agreed to the download.
    @discardableResult
    public func download(_ tier: WhisperModelTier) async -> Bool {
        if tier.isInstalled { return true }
        if let joined = running[tier] { return await joined.value }

        failure[tier] = nil
        progress[tier] = 0
        let task = Task { @MainActor [weak self] () -> Bool in
            do {
                try await Self.fetch(tier) { share in
                    Task { @MainActor in
                        // About a hundred redraws for the whole file.
                        guard let self, let current = self.progress[tier], floor(share * 100) > floor(current * 100) else { return }
                        self.progress[tier] = share
                    }
                }
                return true
            } catch is CancellationError {
                return false
            } catch let error as URLError where error.code == .cancelled {
                return false
            } catch {
                self?.failure[tier] = error.localizedDescription
                return false
            }
        }
        running[tier] = task
        let installed = await task.value
        running[tier] = nil
        progress[tier] = nil
        revision &+= 1
        if installed {
            noteUsed(tier)
            CrashLog.note("whisper model downloaded: \(tier.rawValue)")
        }
        return installed
    }

    public func cancelDownload(_ tier: WhisperModelTier) {
        running[tier]?.cancel()
    }

    public func delete(_ tier: WhisperModelTier) {
        guard (inUse[tier] ?? 0) == 0, running[tier] == nil else { return }
        try? FileManager.default.removeItem(at: tier.localURL)
        failure[tier] = nil
        revision &+= 1
    }

    func beginUse(_ tier: WhisperModelTier) { inUse[tier, default: 0] += 1 }

    func endUse(_ tier: WhisperModelTier) {
        inUse[tier] = max(0, (inUse[tier] ?? 1) - 1)
    }

    /// Streams to a `.part` file next to the model and renames it only when every byte arrived.
    /// A cancelled or failed download leaves nothing behind.
    private nonisolated static func fetch(_ tier: WhisperModelTier, progress: @escaping @Sendable (Double) -> Void) async throws {
        let directory = modelsDirectoryURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let partial = directory.appendingPathComponent(tier.fileName + ".part")
        defer { try? FileManager.default.removeItem(at: partial) }

        let delegate = DownloadProgressDelegate(expected: tier.byteCount, report: progress)
        let (downloaded, response) = try await URLSession.shared.download(from: tier.downloadURL, delegate: delegate)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WhisperError.downloadFailed(String(localized: "The server answered \(http.statusCode)."))
        }

        try? FileManager.default.removeItem(at: partial)
        try FileManager.default.moveItem(at: downloaded, to: partial)
        let size = (try FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.int64Value
        guard size == tier.byteCount else {
            throw WhisperError.downloadFailed(String(localized: "The download was incomplete."))
        }
        try? FileManager.default.removeItem(at: tier.localURL)
        try FileManager.default.moveItem(at: partial, to: tier.localURL)
    }
}

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let expected: Int64
    private let report: @Sendable (Double) -> Void

    init(expected: Int64, report: @escaping @Sendable (Double) -> Void) {
        self.expected = expected
        self.report = report
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expected
        report(min(1, Double(totalBytesWritten) / Double(max(1, total))))
    }

    // The async `download(from:delegate:)` hands back the file itself; this is required by the protocol only.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

public enum WhisperError: LocalizedError {
    case modelMissing(WhisperModelTier)
    case modelUnreadable
    case audioUnreadable
    case downloadFailed(String)
    case failed

    public var errorDescription: String? {
        switch self {
        case .modelMissing(let tier):
            return String(localized: "Download the Whisper \(tier.label) model in Captions first.")
        case .modelUnreadable:
            return String(localized: "The Whisper model could not be loaded. Delete it and download it again.")
        case .audioUnreadable:
            return String(localized: "The recording's audio could not be read.")
        case .downloadFailed(let reason):
            return reason
        case .failed:
            return String(localized: "Whisper could not transcribe this recording.")
        }
    }
}

/// Speech to word timings with whisper.cpp, off the main thread. Metal does the heavy work; the CPU side uses half the cores
/// so the Mac stays usable during a long transcript.
public enum WhisperTranscriber {
    static let sampleRate = 16_000

    /// `locale` is a transcript locale such as `"vi_VN"`, or `"auto"` to let Whisper detect the language.
    public static func transcribe(
        audioURL: URL,
        tier: WhisperModelTier,
        locale: String,
        prompt: String,
        maxDurationMs: Double,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [CaptionSegment] {
        guard tier.isInstalled else { throw WhisperError.modelMissing(tier) }
        let samples = try await readSpeechAudio(from: audioURL)
        try Task.checkCancellation()

        let cancelFlag = CancelFlag()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try run(samples: samples, tier: tier, locale: locale, prompt: prompt, maxDurationMs: maxDurationMs, cancel: cancelFlag, progress: progress)
            }.value
        } onCancel: {
            cancelFlag.set()
        }
    }

    private static func run(
        samples: [Float],
        tier: WhisperModelTier,
        locale: String,
        prompt: String,
        maxDurationMs: Double,
        cancel: CancelFlag,
        progress: (@Sendable (Double) -> Void)?
    ) throws -> [CaptionSegment] {
        whisper_log_set({ _, _, _ in }, nil)
        var contextParams = whisper_context_default_params()
        contextParams.use_gpu = true
        guard let context = tier.localURL.path.withCString({ whisper_init_from_file_with_params($0, contextParams) }) else {
            throw WhisperError.modelUnreadable
        }
        defer { whisper_free(context) }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount / 2))
        params.print_special = false
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        // One segment per word, like Windows.
        params.token_timestamps = true
        params.max_len = 1
        params.split_on_word = true
        params.detect_language = false
        let flag = Unmanaged.passUnretained(cancel).toOpaque()
        params.abort_callback = { data in
            guard let data else { return false }
            return Unmanaged<CancelFlag>.fromOpaque(data).takeUnretainedValue().isSet
        }
        params.abort_callback_user_data = flag

        // whisper reports its percent within each `whisper_full` call. A recording with steady speech is a single region,
        // so progress per finished region would sit at 0% until the end.
        let tracker = ProgressTracker(report: progress)
        params.progress_callback = { _, _, percent, data in
            guard let data else { return }
            Unmanaged<ProgressTracker>.fromOpaque(data).takeUnretainedValue().regionPercent(Int(percent))
        }
        params.progress_callback_user_data = Unmanaged.passUnretained(tracker).toOpaque()

        var words: [(text: String, startMs: Double, endMs: Double)] = []
        let totalMs = max(1, Double(samples.count) * 1000 / Double(sampleRate))
        let regions = SpeechRegions.find(samples, sampleRate: sampleRate)
        let (languageCode, modelPrompt) = forModel(locale: locale, prompt: prompt)

        try languageCode.withCString { languagePointer in
            try modelPrompt.withCString { promptPointer in
                params.language = languagePointer
                params.initial_prompt = modelPrompt.isEmpty ? nil : promptPointer
                for region in regions {
                    if cancel.isSet { throw CancellationError() }
                    let offsetMs = Double(region.start) * 1000 / Double(sampleRate)
                    let regionMs = Double(region.length) * 1000 / Double(sampleRate)
                    tracker.begin(startShare: offsetMs / totalMs, spanShare: regionMs / totalMs)
                    let status = samples.withUnsafeBufferPointer { buffer in
                        whisper_full(context, params, buffer.baseAddress! + region.start, Int32(region.length))
                    }
                    if cancel.isSet { throw CancellationError() }
                    guard status == 0 else { throw WhisperError.failed }

                    for index in 0..<whisper_full_n_segments(context) {
                        guard let text = whisper_full_get_segment_text(context, index) else { continue }
                        // Centiseconds.
                        let start = Double(whisper_full_get_segment_t0(context, index)) * 10 + offsetMs
                        let end = Double(whisper_full_get_segment_t1(context, index)) * 10 + offsetMs
                        words.append((String(cString: text), start, end))
                    }
                    tracker.regionPercent(100)
                }
            }
        }
        withExtendedLifetime(tracker) {}
        return normalize(words, maxDurationMs: maxDurationMs)
    }

    // Whisper has one code for Chinese and writes Simplified characters unless the prompt is in Traditional ones.
    private static let traditionalChinesePrompt = "以下是繁體中文的句子。"

    /// The model's language code (`"vi"`, or `"auto"` to detect it) and its prompt. Same rules as
    /// `TranscriptLanguages.ForModel` on Windows: Taiwan and Hong Kong Chinese get a Traditional sentence before the prompt.
    static func forModel(locale: String, prompt: String) -> (language: String, prompt: String) {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = locale.split(whereSeparator: { $0 == "_" || $0 == "-" }).map(String.init)
        let language = parts.first?.lowercased() ?? ""
        guard language.count == 2 else { return ("auto", prompt) }
        let region = parts.count > 1 ? parts[1].uppercased() : ""
        guard language == "zh", ["TW", "HK", "HANT"].contains(region) else { return (language, prompt) }
        return (language, prompt.isEmpty ? traditionalChinesePrompt : traditionalChinesePrompt + " " + prompt)
    }

    /// `TranscriptSegments.Normalize` on Windows, plus: a word ends where the next one starts. Whisper often stretches the
    /// last word of a sentence into the pause after it, past the next sentence's first word, and the caption blocks
    /// built from the words then overlap on the timeline (spec/06 ADR-105).
    static func normalize(_ words: [(text: String, startMs: Double, endMs: Double)], maxDurationMs: Double) -> [CaptionSegment] {
        let kept = words
            .map { (text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), startMs: $0.startMs, endMs: $0.endMs) }
            .filter { !$0.text.isEmpty }
            .sorted { $0.startMs < $1.startMs }
        var results: [CaptionSegment] = []
        var previousEnd = 0.0
        for (index, word) in kept.enumerated() {
            let start = min(max(previousEnd, word.startMs), maxDurationMs)
            let nextStart = index + 1 < kept.count ? kept[index + 1].startMs : maxDurationMs
            // At least 1 ms long, even when the next word starts at the same time.
            let end = min(max(word.endMs, start + 40), max(nextStart, start + 1), maxDurationMs)
            guard end > start else { continue }
            results.append(CaptionSegment(sourceStartMs: start, sourceEndMs: end, text: word.text))
            previousEnd = end
        }
        return results
    }

    /// The first audio track as 16 kHz mono float samples, which is what Whisper takes.
    static func readSpeechAudio(from url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw WhisperError.audioUnreadable }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ])
        guard reader.canAdd(output) else { throw WhisperError.audioUnreadable }
        reader.add(output)
        guard reader.startReading() else { throw WhisperError.audioUnreadable }

        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let start = samples.count
            samples.append(contentsOf: repeatElement(0, count: length / MemoryLayout<Float>.size))
            _ = samples.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress! + start * MemoryLayout<Float>.size)
            }
        }
        guard reader.status == .completed else { throw WhisperError.audioUnreadable }
        return samples
    }
}

/// Turns whisper's percent within one region into a share of the whole track, reported once per whole percent.
private final class ProgressTracker: @unchecked Sendable {
    private let report: (@Sendable (Double) -> Void)?
    private var startShare = 0.0
    private var spanShare = 0.0
    private var lastPercent = -1

    init(report: (@Sendable (Double) -> Void)?) {
        self.report = report
    }

    func begin(startShare: Double, spanShare: Double) {
        self.startShare = startShare
        self.spanShare = spanShare
        regionPercent(0)
    }

    /// Called on whisper's thread only, so no lock.
    func regionPercent(_ percent: Int) {
        let share = min(1, startShare + spanShare * Double(min(max(percent, 0), 100)) / 100)
        let whole = Int(share * 100)
        guard whole > lastPercent else { return }
        lastPercent = whole
        report?(share)
    }
}

private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// Where speech is in an audio track. Whisper places words wrongly after long silence, up to the whole length of the
/// silence, so each region is transcribed on its own and its words are shifted by the region's start (spec/06 ADR-25).
/// Same constants as `SpeechRegions` on Windows.
enum SpeechRegions {
    private static let windowMs = 30.0
    private static let mergeGapMs = 700.0
    private static let paddingMs = 200.0
    private static let relativeThreshold: Float = 0.05
    private static let absoluteThreshold: Float = 0.002

    static func find(_ samples: [Float], sampleRate: Int) -> [(start: Int, length: Int)] {
        let window = max(1, Int(windowMs / 1000 * Double(sampleRate)))
        let count = samples.count / window
        guard count > 0 else { return [] }
        var levels = [Float](repeating: 0, count: count)
        var loudest: Float = 0
        samples.withUnsafeBufferPointer { buffer in
            for index in 0..<count {
                var sum: Float = 0
                for at in (index * window)..<((index + 1) * window) {
                    sum += buffer[at] * buffer[at]
                }
                levels[index] = (sum / Float(window)).squareRoot()
                loudest = max(loudest, levels[index])
            }
        }

        let threshold = max(absoluteThreshold, loudest * relativeThreshold)
        let mergeGap = Int(mergeGapMs / windowMs)
        let padding = Int(paddingMs / 1000 * Double(sampleRate))
        var regions: [(start: Int, length: Int)] = []
        var first = -1
        var last = -1

        func close() {
            let start = max(0, first * window - padding)
            let end = min(samples.count, (last + 1) * window + padding)
            regions.append((start, end - start))
        }

        for index in 0..<count where levels[index] >= threshold {
            if first >= 0 && index - last > mergeGap {
                close()
                first = -1
            }
            if first < 0 { first = index }
            last = index
        }
        if first >= 0 { close() }
        return regions
    }
}
