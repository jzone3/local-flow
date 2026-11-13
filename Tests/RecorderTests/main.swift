import AVFoundation
import Combine
import Foundation

// Drives the real AudioRecorder through recordings on scripted engines, since CI has no microphone.
// 0.0.23 shipped with green CI and rebuilt its engine on every AVAudioEngineConfigurationChange: each new
// engine re-opened the mic, which posted another change, so holding Fn looped, recorded nothing and froze
// the menu bar. These cases fail on that code path.

/// The one AppSettings field AudioRecorder reads; the app's class drags in the whole UI.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    @Published var inputDeviceUID: String?
}

var failures = 0
func expect(_ condition: Bool, _ label: String, line: Int = #line) {
    if condition { print("ok   \(label)") } else { failures += 1; print("FAIL \(label) (line \(line))") }
}

/// A microphone as the engines see it: when its format changes under a running engine, that engine stops and
/// AVAudioEngineConfigurationChange is posted for it, as CoreAudio does.
final class FakeDevice {
    enum Behavior {
        /// Never changes.
        case stable
        /// Changes format whenever a new engine opens it (Bluetooth headphones flipping into headset mode, or
        /// 0.0.23 setting the device on every fresh engine). An engine restarted in place is left alone.
        case changesWhenOpened
        /// Changes format after every start, new engine or not.
        case changesOnEveryStart
        /// Has no input at all.
        case missing
    }

    let behavior: Behavior
    /// Notifications posted per change; CoreAudio often sends several in a row.
    let burst: Int
    private(set) var engines: [FakeEngine] = []
    private(set) var changesPosted = 0
    private var rates: [Double] = [48_000, 16_000, 24_000, 44_100]

    init(_ behavior: Behavior, burst: Int = 1) {
        self.behavior = behavior
        self.burst = burst
    }

    var format: AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: behavior == .missing ? 0 : rates[0], channels: 2) ?? AVAudioFormat()
    }
    var totalStarts: Int { engines.reduce(0) { $0 + $1.starts } }
    var running: Int { engines.filter(\.isRunning).count }

    func makeEngine() -> AudioInputEngine {
        let engine = FakeEngine(device: self)
        engines.append(engine)
        return engine
    }

    fileprivate func started(_ engine: FakeEngine) {
        let changes: Bool
        switch behavior {
        case .stable, .missing: changes = false
        case .changesWhenOpened: changes = engine.starts == 1
        case .changesOnEveryStart: changes = true
        }
        guard changes else { return }
        // CoreAudio posts the change 60–80 ms after the mic opens.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) { [self] in
            guard engine.isRunning else { return }
            rates.append(rates.removeFirst())
            engine.interrupt()
            for _ in 0..<burst {
                changesPosted += 1
                NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
            }
        }
    }
}

/// Stands in for AVAudioEngine: while running it feeds a tone to its tap every 10 ms in the device's format.
final class FakeEngine: AudioInputEngine {
    private let device: FakeDevice
    private(set) var isRunning = false
    private(set) var starts = 0
    private var tap: ((AVAudioPCMBuffer) -> Void)?
    private var tapFormat: AVAudioFormat?
    private var timer: Timer?

    init(device: FakeDevice) { self.device = device }

    var inputFormat: AVAudioFormat { device.format }
    var inputUnit: AudioUnit? { nil }

    func installInputTap(bufferSize: AVAudioFrameCount, format: AVAudioFormat, block: @escaping (AVAudioPCMBuffer) -> Void) {
        tap = block
        tapFormat = format
    }
    func removeInputTap() { tap = nil; tapFormat = nil }
    func prepare() {}

    func start() throws {
        // AVAudioEngine refuses to start a tap whose format is not the device's current one (-10868).
        if let tapFormat, tapFormat.sampleRate != device.format.sampleRate {
            throw NSError(domain: NSOSStatusErrorDomain, code: -10868)
        }
        starts += 1
        isRunning = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] _ in self?.deliver() }
        device.started(self)
    }

    func stop() { interrupt() }
    func reset() {}

    fileprivate func interrupt() {
        isRunning = false
        timer?.invalidate()
        timer = nil
    }

    private func deliver() {
        guard isRunning, let tap, let format = tapFormat else { return }
        let frames = AVAudioFrameCount(format.sampleRate / 100)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames), let data = buffer.floatChannelData else { return }
        buffer.frameLength = frames
        for channel in 0..<Int(format.channelCount) {
            for i in 0..<Int(frames) { data[channel][i] = 0.25 * sin(Float(i) * 0.3) }
        }
        tap(buffer)
    }
}

func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
func peak(_ samples: [Float]) -> Float { samples.reduce(0) { max($0, abs($1)) } }

// A steady microphone: one engine, one start, audio comes back.
do {
    let device = FakeDevice(.stable)
    let recorder = AudioRecorder(newEngine: device.makeEngine)
    var lost = 0
    recorder.onLost = { lost += 1 }
    try recorder.start()
    spin(0.6)
    let (samples, _) = recorder.stop()
    expect(device.engines.count == 1 && device.totalStarts == 1, "steady mic: one engine, started once (engines \(device.engines.count), starts \(device.totalStarts))")
    expect(samples.count > 4_000 && peak(samples) > 0.1, "steady mic: audio recorded (\(samples.count) samples, peak \(peak(samples)))")
    expect(lost == 0, "steady mic: not reported lost")
    expect(device.running == 0, "steady mic: mic closed after stop")
}

// The 0.0.23 regression: opening the mic changes the device's format. The same engine must restart in place,
// once; building a new engine opens the mic again and never ends.
do {
    let device = FakeDevice(.changesWhenOpened, burst: 3)
    let recorder = AudioRecorder(newEngine: device.makeEngine)
    var lost = 0
    recorder.onLost = { lost += 1 }
    try recorder.start()
    spin(2)
    let stillRecording = recorder.isRecording
    let (samples, _) = recorder.stop()
    expect(device.engines.count == 1, "format change on open: engine restarted in place, not rebuilt (engines built: \(device.engines.count))")
    expect(device.totalStarts == 2, "format change on open: one restart for a burst of notifications (starts: \(device.totalStarts), notifications: \(device.changesPosted))")
    expect(device.changesPosted == 3, "format change on open: the change is not re-triggered (notifications: \(device.changesPosted))")
    expect(stillRecording && lost == 0, "format change on open: still recording")
    expect(samples.count > 16_000 && peak(samples) > 0.1, "format change on open: audio recorded after the restart (\(samples.count) samples, peak \(peak(samples)))")
    expect(device.running == 0, "format change on open: mic closed after stop")
    spin(0.5)
    expect(device.totalStarts == 2, "format change on open: nothing restarts after stop (starts: \(device.totalStarts))")
}

// A device that changes after every start: restarts are capped, then the recording is reported lost instead of spinning.
do {
    let device = FakeDevice(.changesOnEveryStart)
    let recorder = AudioRecorder(newEngine: device.makeEngine)
    var lost = 0
    recorder.onLost = { lost += 1 }
    try recorder.start()
    spin(3)
    expect(device.engines.count == 1, "device keeps changing: engine never rebuilt (engines built: \(device.engines.count))")
    expect(device.totalStarts == 1 + AudioRecorder.maxRestarts, "device keeps changing: restarts capped at \(AudioRecorder.maxRestarts) (starts: \(device.totalStarts))")
    expect(lost == 1, "device keeps changing: reported lost once (\(lost))")
    expect(device.running == 0, "device keeps changing: engine left stopped")
    _ = recorder.stop()
}

// No microphone: start fails and nothing is left running.
do {
    let device = FakeDevice(.missing)
    let recorder = AudioRecorder(newEngine: device.makeEngine)
    var threw = false
    do { try recorder.start() } catch { threw = true }
    spin(0.3)
    expect(threw && !recorder.isRecording, "no microphone: start fails")
    expect(device.totalStarts == 0 && device.running == 0, "no microphone: nothing left running")
}

if failures == 0 { print("recorder tests passed") } else { print("\(failures) failure(s)"); exit(1) }
