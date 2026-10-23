import SwiftUI
import UIKit

/// One dictation at a time: listen → transcribe on-device → copy to the clipboard and hand to the keyboard.
@MainActor
final class DictationModel: ObservableObject {
    enum Phase: Equatable { case idle, listening, transcribing, done, failed(String) }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var transcript = SharedStore.lastTranscript ?? ""
    /// True when the keyboard opened the app, so there is an app to go back to.
    @Published private(set) var cameFromKeyboard = false
    @Published private(set) var peakMemoryMB: Int?

    let recorder = Recorder()
    private var startedAt: Date?
    private var pendingStart = false
    private var pendingSamples: [Float]?
    private var pressStartedAt: Date?
    private var stopOnRelease = false
    /// The app the keyboard was typing in; we go back to it once the text is copied.
    private var returnBundleID: String?

    var isListening: Bool { phase == .listening }

    // MARK: Button

    /// Finger down on the big button. Tap = toggle; holding past `holdThreshold` = talk until release.
    func pressBegan() {
        pressStartedAt = Date()
        switch phase {
        case .listening: stopOnRelease = true
        case .transcribing: break
        default:
            stopOnRelease = false
            Task { await start() }
        }
    }

    func pressEnded() {
        defer { pressStartedAt = nil; stopOnRelease = false }
        guard phase == .listening else { return }
        let held = pressStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        if stopOnRelease || held >= Self.holdThreshold { stop() }
    }

    static let holdThreshold: TimeInterval = 0.5

    func toggle() {
        if phase == .listening { stop() } else if phase != .transcribing { Task { await start() } }
    }

    // MARK: Opened by the keyboard

    func handle(_ url: URL, modelReady: Bool) {
        guard url.scheme == "localflow", url.host == "dictate" else { return }
        cameFromKeyboard = true
        returnBundleID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == SharedStore.returnQueryItem }?.value
        pendingStart = true
        if modelReady { startIfRequested() }
    }

    func startIfRequested() {
        guard pendingStart else { return }
        pendingStart = false
        if phase != .listening, phase != .transcribing { Task { await start() } }
    }

    func scenePhaseChanged(_ scenePhase: ScenePhase) {
        if scenePhase == .background, phase == .listening {
            // The mic stops in the background; keep what was said and transcribe on return (Metal needs the foreground).
            pendingSamples = recorder.stop()
            phase = .idle
        }
        if scenePhase == .active, let samples = pendingSamples {
            pendingSamples = nil
            transcribe(samples)
        }
    }

    // MARK: Recording

    func start() async {
        guard phase != .listening, phase != .transcribing else { return }
        guard await Recorder.requestPermission() else {
            phase = .failed("Microphone is off. Turn it on in Settings → Local Flow.")
            return
        }
        do {
            try recorder.start()
            startedAt = Date()
            phase = .listening
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func stop() {
        guard phase == .listening else { return }
        let samples = recorder.stop()
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        // Only an accidental tap is dropped; quiet audio still goes to the model.
        guard duration > 0.35 else { phase = .idle; return }
        transcribe(samples)
    }

    private func transcribe(_ samples: [Float]) {
        phase = .transcribing
        let vocabulary = Vocabulary(text: UserDefaults.standard.string(forKey: "vocabulary") ?? Vocabulary.defaultText)
        let sampler = MemorySampler()
        Task {
            sampler.start()
            defer { peakMemoryMB = sampler.stop() }
            do {
                let raw = try await WhisperEngine.shared.transcribe(samples, hint: vocabulary.promptHint())
                let text = TextCleanup.clean(vocabulary.applySpelling(to: raw), profile: .standard, vocabulary: vocabulary)
                DebugLog.write("transcribed \(samples.count) samples → \(text.count) chars; peak footprint \(sampler.peak) MB")
                if text.isEmpty || TextCleanup.isHallucination(text) {
                    phase = .failed("Didn't catch anything.")
                    return
                }
                transcript = text
                UIPasteboard.general.string = text
                SharedStore.lastTranscript = text
                phase = .done
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                goBack()
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Shows "Copied" for a moment, then reopens the app the keyboard came from. If that fails, the ◀ hint stays.
    private func goBack() {
        guard let bundleID = returnBundleID else { return }
        returnBundleID = nil
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard phase == .done else { return }
            let ok = ReturnToHost.open(bundleID)
            DebugLog.write("return to \(bundleID): \(ok)")
        }
    }
}

/// Samples the memory footprint four times a second while a transcription runs and keeps the peak.
final class MemorySampler {
    private(set) var peak = 0
    private var timer: Timer?

    func start() {
        peak = Memory.footprintMB
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.peak = max(self.peak, Memory.footprintMB)
        }
    }

    func stop() -> Int {
        timer?.invalidate()
        peak = max(peak, Memory.footprintMB)
        return peak
    }
}
