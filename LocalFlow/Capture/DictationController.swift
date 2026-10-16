import AppKit
import Combine
import Foundation

/// The hold-to-talk state machine: hotkey down → record and show the bar; up → transcribe, paste, save to history.
@MainActor
final class DictationController: ObservableObject {
    static let shared = DictationController()

    enum State: Equatable {
        case idle
        case listening
        case transcribing
        case done(String)
        case failed(String)

        var isActive: Bool { self == .listening || self == .transcribing }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastWarning: String?
    @Published private(set) var permissionProblem: String?

    let recorder = AudioRecorder()
    private let settings = AppSettings.shared
    private lazy var hotkey = HotkeyMonitor(hotkey: settings.hotkey)
    private let bar = DictationBarPanel()
    private var transcription: Task<Void, Never>?
    private var hideWork: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []
    private var startedAt: Date?

    var statusLine: String {
        switch state {
        case .idle: return "Hold \(settings.hotkey.displayName) to dictate"
        case .listening: return "Listening…"
        case .transcribing: return "Transcribing…"
        case .done: return "Pasted"
        case .failed(let message): return message
        }
    }

    func start() {
        hotkey.onPress = { [weak self] in self?.beginRecording() }
        hotkey.onRelease = { [weak self] in self?.endRecording() }
        hotkey.onCancel = { [weak self] in self?.cancel() }
        hotkey.start()
        settings.$hotkey.dropFirst().sink { [weak self] key in self?.hotkey.update(hotkey: key) }.store(in: &cancellables)
        bar.attach(recorder: recorder, controller: self)
        refreshPermissions()
    }

    func refreshPermissions() {
        if !HotkeyMonitor.hasAccessibility {
            permissionProblem = "Local Flow needs Accessibility access to see the hotkey and paste into other apps."
        } else if !AudioRecorder.hasPermission {
            permissionProblem = "Local Flow needs microphone access."
        } else {
            permissionProblem = nil
        }
    }

    private func beginRecording() {
        guard !state.isActive else { return }
        transcription?.cancel()
        hideWork?.cancel()
        guard AudioRecorder.hasPermission else {
            Task { if await AudioRecorder.requestPermission() { self.refreshPermissions() } }
            return
        }
        do {
            try recorder.start()
            startedAt = Date()
            state = .listening
            if settings.playSounds { NSSound(named: "Tink")?.play() }
            bar.show()
        } catch {
            show(failure: error.localizedDescription)
        }
    }

    private func endRecording() {
        guard state == .listening else { return }
        let (samples, duration) = recorder.stop()
        guard duration > 0.35, samples.contains(where: { abs($0) > 0.005 }) else {
            state = .idle
            bar.hide()
            return
        }
        state = .transcribing
        let entryID = UUID()
        let audioURL = HistoryStore.shared.newAudioURL(id: entryID)
        let wav = AudioRecorder.wavData(from: samples)
        try? wav.write(to: audioURL, options: [.atomic, .completeFileProtection])

        transcription = Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await TranscriptionService().transcribe(samples: samples)
                guard !Task.isCancelled else { return }
                lastWarning = outcome.warning
                if outcome.text.isEmpty {
                    show(failure: "Didn't catch anything.")
                    try? FileManager.default.removeItem(at: audioURL)
                    return
                }
                HistoryStore.shared.add(HistoryEntry(id: entryID, date: Date(), text: outcome.text, rawText: outcome.rawText,
                                                     engine: outcome.engine, durationSeconds: duration, audioFileName: audioURL.lastPathComponent))
                TextInserter.insert(outcome.text)
                if settings.playSounds { NSSound(named: "Pop")?.play() }
                state = .done(outcome.text)
                scheduleHide(after: outcome.warning == nil ? 1.2 : 3)
            } catch {
                guard !Task.isCancelled else { return }
                try? FileManager.default.removeItem(at: audioURL)
                show(failure: error.localizedDescription)
            }
        }
    }

    func cancel() {
        transcription?.cancel()
        if recorder.isRecording { _ = recorder.stop() }
        state = .idle
        bar.hide()
    }

    private func show(failure: String) {
        state = .failed(failure)
        bar.show()
        scheduleHide(after: 4)
    }

    private func scheduleHide(after seconds: TimeInterval) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !state.isActive else { return }
            bar.hide()
            state = .idle
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}
