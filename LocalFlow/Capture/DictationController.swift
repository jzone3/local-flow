import AppKit
import Combine
import Foundation

/// The hold-to-talk state machine: hotkey down → record and show the bar; up → transcribe, paste, save to history.
/// Double-tap the hotkey to keep listening hands-free; the next tap stops.
@MainActor
final class DictationController: ObservableObject {
    static let shared = DictationController()

    enum State: Equatable {
        case idle
        case listening
        case transcribing
        case done
        case failed(String)

        var isActive: Bool { self == .listening || self == .transcribing }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastWarning: String?
    @Published private(set) var transcribingText = "Transcribing…"
    @Published private(set) var permissionProblem: String?
    @Published private(set) var hasMicrophone = AudioRecorder.hasPermission
    @Published private(set) var hasAccessibility = HotkeyMonitor.hasAccessibility
    @Published private(set) var handsFree = false

    let recorder = AudioRecorder()
    private let settings = AppSettings.shared
    private lazy var hotkey = HotkeyMonitor(hotkey: settings.hotkey)
    private let bar = DictationBarPanel()
    private var transcription: Task<Void, Never>?
    private var hideWork: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []
    private var startedAt: Date?
    private var profile: CleanupProfile = .standard
    private var pressedAt: Date?
    private var lastTapAt: Date?
    private var ignoreNextRelease = false
    private let tapMaxHold: TimeInterval = 0.3
    private let doubleTapWindow: TimeInterval = 0.5
    static let copiedMessage = "Copied to the clipboard."
    private static let microphoneOff = "Microphone access is off. Turn it on in System Settings → Privacy & Security → Microphone."

    var statusLine: String {
        switch state {
        case .idle: return "Hold or double-tap \(settings.hotkey.displayName) to dictate"
        case .listening: return "Listening…"
        case .transcribing: return transcribingText
        case .done: return "Pasted"
        case .failed(let message): return message
        }
    }

    func start() {
        hotkey.onPress = { [weak self] in self?.hotkeyPressed() }
        hotkey.onRelease = { [weak self] in self?.hotkeyReleased() }
        hotkey.onCancel = { [weak self] in self?.cancel() }
        hotkey.start()
        settings.$hotkey.dropFirst().sink { [weak self] key in self?.hotkey.update(hotkey: key) }.store(in: &cancellables)
        bar.attach(recorder: recorder, controller: self)
        LocalWhisper.shared.onModelLoading = { [weak self] loading in
            guard let self, state == .transcribing else { return }
            transcribingText = loading ? "Loading model…" : TranscriptionService.transcribingLabel()
        }
        refreshPermissions()
    }

    var hotkeyPaused: Bool {
        get { hotkey.isPaused }
        set { hotkey.isPaused = newValue }
    }

    func refreshPermissions() {
        hasMicrophone = AudioRecorder.hasPermission
        hasAccessibility = HotkeyMonitor.hasAccessibility
        if !HotkeyMonitor.hasAccessibility {
            permissionProblem = "Local Flow needs Accessibility access to see the hotkey and paste into other apps."
        } else if !AudioRecorder.hasPermission {
            permissionProblem = "Local Flow needs microphone access."
        } else {
            permissionProblem = nil
        }
        if hasAccessibility, !hotkey.usesEventTap { hotkey.start() }  // upgrade to the event tap once trusted
    }

    private func hotkeyPressed() {
        if handsFree {
            ignoreNextRelease = true
            endRecording()
            return
        }
        pressedAt = Date()
        beginRecording()
    }

    private func hotkeyReleased() {
        if ignoreNextRelease { ignoreNextRelease = false; return }
        let now = Date()
        let wasTap = pressedAt.map { now.timeIntervalSince($0) < tapMaxHold } ?? false
        if wasTap, let last = lastTapAt, now.timeIntervalSince(last) < doubleTapWindow, state == .listening {
            handsFree = true
            hotkey.escapeArmed = true
            lastTapAt = nil
            return
        }
        lastTapAt = wasTap ? now : nil
        endRecording()
    }

    private func beginRecording() {
        guard !state.isActive else { return }
        transcription?.cancel()
        hideWork?.cancel()
        guard AudioRecorder.hasPermission else {
            if AudioRecorder.isDenied {
                show(failure: Self.microphoneOff)
            } else {
                Task {
                    if await AudioRecorder.requestPermission() { self.refreshPermissions() }
                    else { self.show(failure: Self.microphoneOff) }  // "Don't Allow" on the prompt
                }
            }
            return
        }
        do {
            try recorder.start()
            startedAt = Date()
            profile = Self.targetProfile()
            state = .listening
            if settings.playSounds { NSSound(named: "Tink")?.play() }
            bar.show()
        } catch {
            show(failure: error.localizedDescription)
        }
    }

    private func endRecording() {
        handsFree = false
        hotkey.escapeArmed = false
        guard state == .listening else { return }
        let (samples, duration) = recorder.stop()
        // Only an accidental tap is dropped. Quiet audio always goes to the model (a low input level is not silence);
        // if the model hears nothing, `isHallucination` reports "Didn't catch anything."
        guard duration > 0.35 else {
            state = .idle
            bar.hide()
            return
        }
        if !AudioRecorder.hasPermission {
            show(failure: Self.microphoneOff)  // revoked while running: the engine delivers silence
            return
        }
        transcribingText = TranscriptionService.transcribingLabel()
        if settings.engineMode == .local, !LocalWhisper.shared.isReady(WhisperModel.active) {
            transcribingText = "Loading model…"  // the local engine confirms via onModelLoading once the context is up
        }
        state = .transcribing
        hotkey.escapeArmed = true  // Esc still cancels while the cloud round trip runs
        let entryID = UUID()
        let audioURL = HistoryStore.shared.newAudioURL(id: entryID)
        let wav = AudioRecorder.wavData(from: samples)
        try? wav.write(to: audioURL, options: [.atomic, .completeFileProtection])

        transcription = Task { [weak self] in
            guard let self else { return }
            defer { hotkey.escapeArmed = false }
            do {
                let outcome = try await TranscriptionService().transcribe(samples: samples, profile: profile)
                guard !Task.isCancelled else { return }
                lastWarning = outcome.warning.map(Self.friendly)
                if TextCleanup.isHallucination(outcome.text) {
                    keepFailed(entryID, audioURL: audioURL, duration: duration, engine: outcome.engine, error: "Didn't catch anything.", details: outcome.details)
                    show(failure: "Didn't catch anything.")
                    return
                }
                HistoryStore.shared.add(HistoryEntry(id: entryID, date: Date(), text: outcome.text, rawText: outcome.rawText,
                                                     engine: outcome.engine, durationSeconds: duration, audioFileName: audioURL.lastPathComponent,
                                                     details: outcome.details))
                TextInserter.insert(outcome.text)
                if settings.playSounds { NSSound(named: "Pop")?.play() }
                if outcome.warning == nil {
                    state = .idle
                    bar.hide()
                } else {
                    state = .done
                    scheduleHide(after: 3)
                }
            } catch {
                guard !Task.isCancelled else { return }
                keepFailed(entryID, audioURL: audioURL, duration: duration, engine: settings.engineLine, error: Self.friendly(error.localizedDescription), details: nil)
                show(failure: error.localizedDescription)
            }
        }
    }

    /// A failed dictation stays in History with its recording, so it can be played back or retried.
    private func keepFailed(_ id: UUID, audioURL: URL, duration: Double, engine: String, error: String, details: TranscriptionDetails?) {
        HistoryStore.shared.add(HistoryEntry(id: id, date: Date(), text: "", rawText: "", engine: engine, durationSeconds: duration,
                                             audioFileName: audioURL.lastPathComponent, details: details, error: error))
    }

    /// Transcribes a history entry's recording again (the menu's "Retry Last Dictation" and the Retry button in
    /// History). The text goes to the clipboard, not to the app in front: the cursor has long moved on.
    func retry(_ entry: HistoryEntry) {
        guard !state.isActive, let url = HistoryStore.shared.audioURL(for: entry),
              let data = try? Data(contentsOf: url), let samples = AudioRecorder.samples(fromWAV: data) else {
            show(failure: "The recording is gone.")
            return
        }
        transcribingText = TranscriptionService.transcribingLabel()
        state = .transcribing
        bar.show()
        transcription = Task { [weak self] in
            guard let self else { return }
            var updated = entry
            do {
                let outcome = try await TranscriptionService().transcribe(samples: samples, profile: .standard)
                guard !Task.isCancelled else { return }
                if TextCleanup.isHallucination(outcome.text) {
                    updated.error = "Didn't catch anything."
                    HistoryStore.shared.update(updated)
                    show(failure: "Didn't catch anything.")
                    return
                }
                updated.text = outcome.text
                updated.rawText = outcome.rawText
                updated.engine = outcome.engine
                updated.details = outcome.details
                updated.error = nil
                updated.date = Date()  // a retried dictation is the newest thing that happened
                HistoryStore.shared.update(updated)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(outcome.text, forType: .string)
                lastWarning = Self.copiedMessage
                state = .done
                scheduleHide(after: 2.5)
            } catch {
                guard !Task.isCancelled else { return }
                updated.error = Self.friendly(error.localizedDescription)
                HistoryStore.shared.update(updated)
                show(failure: error.localizedDescription)
            }
        }
    }

    var lastEntry: HistoryEntry? { HistoryStore.shared.entries.max { $0.date < $1.date } }

    // MARK: Files

    private var fileQueue: [URL] = []
    private var fileRunning = false

    /// Audio or video files from Finder (Services, Open With), a drop on one of our windows, or the menu's
    /// "Transcribe File…". Each becomes a History entry; the text goes to the clipboard. Runs one at a time, after
    /// any dictation in progress.
    func transcribeFiles(_ urls: [URL]) {
        let accepted = urls.filter(FileAudio.isSupported)
        if accepted.isEmpty, let first = urls.first {
            show(failure: "\(first.lastPathComponent) isn't an audio or video file.")
            return
        }
        fileQueue.append(contentsOf: accepted)
        drainFileQueue()
    }

    private func drainFileQueue() {
        guard !fileRunning, !state.isActive, !fileQueue.isEmpty else { return }
        let url = fileQueue.removeFirst()
        fileRunning = true
        Task { [weak self] in
            await self?.transcribeFile(url)
            self?.fileRunning = false
            self?.drainFileQueue()
        }
    }

    private func transcribeFile(_ url: URL) async {
        transcribingText = "Reading \(url.lastPathComponent)…"
        state = .transcribing
        bar.show()
        let samples: [Float]
        do {
            samples = try await FileAudio.samples(from: url)
        } catch {
            show(failure: error.localizedDescription)
            return
        }
        let duration = Double(samples.count) / AudioRecorder.sampleRate
        guard duration > 0.35 else {
            show(failure: "\(url.lastPathComponent) has no sound in it.")
            return
        }
        let entryID = UUID()
        let audioURL = HistoryStore.shared.newAudioURL(id: entryID)
        try? AudioRecorder.wavData(from: samples).write(to: audioURL, options: [.atomic, .completeFileProtection])
        transcribingText = "Transcribing \(url.lastPathComponent)…"
        do {
            let outcome = try await TranscriptionService().transcribe(samples: samples, profile: .standard)
            if TextCleanup.isHallucination(outcome.text) {
                keepFailed(entryID, audioURL: audioURL, duration: duration, engine: outcome.engine, error: "Didn't catch anything in \(url.lastPathComponent).", details: outcome.details)
                show(failure: "Didn't catch anything in \(url.lastPathComponent).")
                return
            }
            HistoryStore.shared.add(HistoryEntry(id: entryID, date: Date(), text: outcome.text, rawText: outcome.rawText,
                                                 engine: outcome.engine, durationSeconds: duration, audioFileName: audioURL.lastPathComponent,
                                                 details: outcome.details, source: url.lastPathComponent))
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(outcome.text, forType: .string)
            lastWarning = Self.copiedMessage
            state = .done
            scheduleHide(after: 2.5)
        } catch {
            keepFailed(entryID, audioURL: audioURL, duration: duration, engine: settings.engineLine, error: Self.friendly(error.localizedDescription), details: nil)
            show(failure: error.localizedDescription)
        }
    }

    func retryLast() {
        if let entry = lastEntry { retry(entry) }
    }

    /// The app the text will land in is the one in front: Local Flow is an accessory app and never takes that spot.
    private static func targetProfile() -> CleanupProfile {
        let focused = HotkeyMonitor.hasAccessibility ? TextInserter.focusedElement() : nil
        return CleanupProfile.for(bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                                  focusedRole: focused?.role, focusedDescription: focused?.description)
    }

    func cancel() {
        handsFree = false
        hotkey.escapeArmed = false
        transcription?.cancel()
        if recorder.isRecording { _ = recorder.stop() }
        state = .idle
        bar.hide()
    }

    /// Server errors arrive as raw JSON bodies; the bar shows one plain line instead.
    static func friendly(_ message: String) -> String {
        var text = message
        for pattern in ["\\{.*\\}", "<.*>"] {   // drop a JSON object or HTML block but keep the sentence around it
            text = text.replacingOccurrences(of: pattern, with: "", options: [.regularExpression])
        }
        text = text.replacingOccurrences(of: "\\s*:\\s*\\)", with: ")", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\.\\s*\\)", with: ")", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\(\\s*\\)", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " :-\n\t"))
        if text.count < 8 { text = "Transcription failed. Check your key in Settings." }
        if text.count > 120 { text = String(text.prefix(117)) + "…" }
        return text
    }

    private func show(failure: String) {
        state = .failed(Self.friendly(failure))
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
