import AVFoundation
import AudioToolbox
import CoreAudio
import Combine
import Foundation

/// Records the default microphone as 16 kHz mono float samples (what Whisper and the cloud APIs want) and
/// publishes a smoothed level for the bar's waveform.
final class AudioRecorder: ObservableObject {
    static let sampleRate: Double = 16_000

    @Published private(set) var level: Float = 0
    @Published private(set) var levels: [Float] = Array(repeating: 0, count: 24)
    /// Level while the Settings mic test is open; audio is not kept.
    @Published private(set) var monitorLevel: Float = 0
    private var gain = AutoGain()
    private var monitoring = false
    /// Settings' mic test is on screen; a dictation pauses the meter and it comes back after, only while this is true.
    private var monitorWanted = false
    private var monitorCancellable: AnyCancellable?

    /// A fresh engine per recording, dropped when it ends: a kept engine holds the mic open, which leaves Bluetooth
    /// headphones in low-quality headset mode, and its cached input format goes stale when the device changes (-10868).
    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    /// Puts the current mode's tap (recording or the Settings meter) on an input node, for the first start and
    /// for restarts after the device's format changed.
    private var tapInstaller: ((AVAudioInputNode) throws -> Void)?
    private var restartWork: DispatchWorkItem?
    private var restarts = 0
    private static let maxRestarts = 3
    private static let restartDelay: TimeInterval = 0.25
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()
    private(set) var isRecording = false
    private var startedAt: Date?

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    static var hasPermission: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    /// True once the user has answered the system prompt with "Don't Allow"; only System Settings can change it then.
    static var isDenied: Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        return status == .denied || status == .restricted
    }

    func start() throws {
        gain.reset()
        guard !isRecording else { return }
        pauseMonitoring()
        samples = []
        do {
            try startEngine()
        } catch {
            // Bluetooth headphones switch into headset mode when the mic opens, and the first start can fail mid-switch.
            releaseEngine()
            Thread.sleep(forTimeInterval: 0.3)
            do { try startEngine() } catch { releaseEngine(); resumeMonitoringIfWanted(); throw error }
        }
        isRecording = true
        startedAt = Date()
    }

    private func startEngine() throws {
        try makeEngine { [weak self] input in try self?.installRecordingTap(on: input) }
    }

    private static let noMicrophone = NSError(domain: "LocalFlow.Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone is available."])

    private func installRecordingTap(on input: AVAudioInputNode) throws {
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw Self.noMicrophone }
        let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false)!
        // Mix every input channel down to mono ourselves (the converter would only keep channel 0, so a mic
        // on input 2 of an interface or a multi-channel virtual device would record silence).
        let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputFormat.sampleRate, channels: 1, interleaved: false)!
        converter = AVAudioConverter(from: monoFormat, to: outputFormat)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let mono = Self.mixedToMono(buffer, format: monoFormat) else { return }
            self.consume(mono, outputFormat: outputFormat)
        }
    }

    /// A new engine on the chosen device with `tap` on its input, started. The device is picked once, here: doing
    /// it again on every restart is what made 0.0.23 loop (see `observeConfigurationChange`).
    private func makeEngine(tap: @escaping (AVAudioInputNode) throws -> Void) throws {
        let engine = AVAudioEngine()
        self.engine = engine
        tapInstaller = tap
        restarts = 0
        observeConfigurationChange(of: engine)
        let input = engine.inputNode
        selectDevice(on: input)
        try tap(input)
        engine.prepare()
        try engine.start()
    }

    /// The device changed under a running engine (unplugged, switched, or Bluetooth headphones flipping into headset
    /// mode right after the mic opens): the engine has stopped, so bring it back and keep what was recorded so far.
    /// CoreAudio can post this several times in a row, and opening the mic is itself what changes some devices'
    /// format, so a notification does not rebuild the engine (that re-opened the mic, which posted another one:
    /// 0.0.23 spun on the main thread, the mic indicator flashed and the menu bar froze). The same engine restarts
    /// in place with the new format, one restart per burst, and after a few in one session it stays stopped.
    private func observeConfigurationChange(of engine: AVAudioEngine) {
        configObserver.map(NotificationCenter.default.removeObserver)
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self, self.engine === engine else { return }
            restartWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.restartEngine() }
            restartWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.restartDelay, execute: work)
        }
    }

    private func restartEngine() {
        guard let engine, isRecording || monitoring, let tapInstaller, restarts < Self.maxRestarts else { return }
        restarts += 1
        engine.inputNode.removeTap(onBus: 0)
        do {
            try tapInstaller(engine.inputNode)
            engine.prepare()
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
        }
    }

    private func releaseEngine() {
        restartWork?.cancel()
        restartWork = nil
        tapInstaller = nil
        configObserver.map(NotificationCenter.default.removeObserver)
        configObserver = nil
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        self.engine = nil
    }

    /// Settings mic test: runs the engine with a tap that only measures level. Stops itself when a real
    /// recording starts and restarts when the chosen device changes.
    func startMonitoring() {
        monitorWanted = true
        guard !monitoring, !isRecording, Self.hasPermission else { return }
        monitoring = true
        do {
            try makeEngine { [weak self] input in try self?.installMonitorTap(on: input) }
        } catch {
            monitoring = false
            releaseEngine()
            return
        }
        monitorCancellable = AppSettings.shared.$inputDeviceUID.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.pauseMonitoring(); self?.resumeMonitoringIfWanted() }
        }
    }

    private func installMonitorTap(on input: AVAudioInputNode) throws {
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Self.noMicrophone }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self, let mono = Self.mixedToMono(buffer), let data = mono.floatChannelData, mono.frameLength > 0 else { return }
            let chunk = UnsafeBufferPointer(start: data[0], count: Int(mono.frameLength))
            let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count))
            // The Settings meter is a true reading on a fixed scale (−60…−10 dB), unlike the bar's auto-gained waveform.
            let normalized = min(1, max(0, (20 * log10(max(rms, 1e-6)) + 60) / 50))
            DispatchQueue.main.async { self.monitorLevel = self.monitorLevel * 0.5 + normalized * 0.5 }
        }
    }

    func stopMonitoring() {
        monitorWanted = false
        pauseMonitoring()
    }

    private func pauseMonitoring() {
        guard monitoring else { return }
        monitoring = false
        monitorCancellable = nil
        releaseEngine()
        monitorLevel = 0
    }

    private func resumeMonitoringIfWanted() {
        if monitorWanted { startMonitoring() }
    }

    /// Points the input node at the microphone chosen in Settings. With no choice (or an unplugged one) it goes
    /// back to the system default explicitly: the input unit otherwise keeps whatever device was set last.
    private func selectDevice(on input: AVAudioInputNode) {
        guard let unit = input.audioUnit else { return }
        let devices = AudioInputDevice.all
        let picked = AppSettings.shared.inputDeviceUID.flatMap { uid in devices.first { $0.uid == uid } }
        guard let device = picked ?? AudioInputDevice.systemDefault else { return }
        var id = device.id
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                             &id, UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    /// Stops and returns the captured samples plus their duration in seconds.
    func stop() -> (samples: [Float], duration: Double) {
        guard isRecording else { return ([], 0) }
        releaseEngine()
        isRecording = false
        DispatchQueue.main.async { self.resumeMonitoringIfWanted() }
        lock.lock(); let captured = samples; samples = []; lock.unlock()
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? Double(captured.count) / Self.sampleRate
        DispatchQueue.main.async { self.level = 0; self.levels = Array(repeating: 0, count: self.levels.count) }
        return (captured, duration)
    }

    private func consume(_ buffer: AVAudioPCMBuffer, outputFormat: AVAudioFormat) {
        guard let converter else { return }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.floatChannelData, out.frameLength > 0 else { return }
        let chunk = Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
        lock.lock(); samples.append(contentsOf: chunk); lock.unlock()
        let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count))
        DispatchQueue.main.async {
            let normalized = self.gain.level(rms: rms)
            self.level = self.level * 0.6 + normalized * 0.4
            self.levels.removeFirst()
            self.levels.append(self.level)
        }
    }

    /// Averages all channels of `buffer` into a mono buffer at the same sample rate.
    static func mixedToMono(_ buffer: AVAudioPCMBuffer, format: AVAudioFormat? = nil) -> AVAudioPCMBuffer? {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0, let src = buffer.floatChannelData else { return nil }
        let monoFormat = format ?? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate, channels: 1, interleaved: false)!
        guard let out = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(frames)), let dst = out.floatChannelData else { return nil }
        out.frameLength = AVAudioFrameCount(frames)
        if buffer.format.isInterleaved {
            let interleaved = src[0]
            for i in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += interleaved[i * channels + c] }
                dst[0][i] = sum / Float(channels)
            }
        } else {
            let scale = 1 / Float(channels)
            for i in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += src[c][i] }
                dst[0][i] = sum * scale
            }
        }
        // Averaging quiets a source that sits on one channel of many (−24 dB on a 16-channel device), so bring
        // the mix back up to the loudest channel's peak. A normal stereo mic (same signal on both) stays at gain 1.
        var channelPeak: Float = 0
        for c in 0..<channels {
            let stride = buffer.format.isInterleaved ? channels : 1
            let base = buffer.format.isInterleaved ? src[0] + c : src[c]
            for i in 0..<frames { channelPeak = max(channelPeak, abs(base[i * stride])) }
        }
        var monoPeak: Float = 0
        for i in 0..<frames { monoPeak = max(monoPeak, abs(dst[0][i])) }
        if monoPeak > 0, channelPeak / monoPeak > 1.001 {
            let gain = min(Float(channels), channelPeak / monoPeak)
            for i in 0..<frames { dst[0][i] *= gain }
        }
        return out
    }

    /// 16-bit PCM WAV, the format every provider accepts.
    /// Reads a WAV written by `wavData` (16-bit mono PCM, 44-byte header) back into samples.
    static func samples(fromWAV data: Data) -> [Float]? {
        guard data.count > 44, data.prefix(4) == Data("RIFF".utf8) else { return nil }
        let pcm = data.dropFirst(44)
        var out = [Float](); out.reserveCapacity(pcm.count / 2)
        var i = pcm.startIndex
        while i + 1 < pcm.endIndex {
            let v = Int16(bitPattern: UInt16(pcm[i]) | (UInt16(pcm[i + 1]) << 8))
            out.append(Float(v) / Float(Int16.max))
            i += 2
        }
        return out
    }

    static func wavData(from samples: [Float], sampleRate: Int = Int(AudioRecorder.sampleRate)) -> Data {
        var pcm = Data(capacity: samples.count * 2)
        for s in samples {
            let clamped = max(-1, min(1, s))
            var v = Int16(clamped * Float(Int16.max))
            withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) }
        }
        var data = Data()
        func put(_ v: UInt32) { var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        func put16(_ v: UInt16) { var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + pcm.count)); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); put(16); put16(1); put16(1)
        put(UInt32(sampleRate)); put(UInt32(sampleRate * 2)); put16(2); put16(16)
        data.append(contentsOf: Array("data".utf8)); put(UInt32(pcm.count))
        data.append(pcm)
        return data
    }
}
