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
    private var monitoring = false
    private var monitorCancellable: AnyCancellable?

    private let engine = AVAudioEngine()
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

    func start() throws {
        guard !isRecording else { return }
        stopMonitoring()
        samples = []
        let input = engine.inputNode
        selectDevice(on: input)
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(domain: "LocalFlow.Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone is available."])
        }
        let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false)!
        converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.consume(buffer, outputFormat: outputFormat)
        }
        engine.prepare()
        try engine.start()
        isRecording = true
        startedAt = Date()
    }

    /// Settings mic test: runs the engine with a tap that only measures level. Stops itself when a real
    /// recording starts and restarts when the chosen device changes.
    func startMonitoring() {
        guard !monitoring, !isRecording, Self.hasPermission else { return }
        monitoring = true
        let input = engine.inputNode
        selectDevice(on: input)
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { monitoring = false; return }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self, let data = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            let chunk = UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength))
            let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count))
            let normalized = min(1, max(0, (20 * log10(max(rms, 1e-6)) + 50) / 50))
            DispatchQueue.main.async { self.monitorLevel = self.monitorLevel * 0.5 + normalized * 0.5 }
        }
        engine.prepare()
        try? engine.start()
        monitorCancellable = AppSettings.shared.$inputDeviceUID.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.stopMonitoring(); self?.startMonitoring() }
        }
    }

    func stopMonitoring() {
        guard monitoring else { return }
        monitoring = false
        monitorCancellable = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        monitorLevel = 0
    }

    /// Points the input node at the microphone chosen in Settings (system default when none is chosen).
    private func selectDevice(on input: AVAudioInputNode) {
        guard let uid = AppSettings.shared.inputDeviceUID,
              let device = AudioInputDevice.all.first(where: { $0.uid == uid }),
              let unit = input.audioUnit else { return }
        var id = device.id
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                             &id, UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    /// Stops and returns the captured samples plus their duration in seconds.
    func stop() -> (samples: [Float], duration: Double) {
        guard isRecording else { return ([], 0) }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
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
        let normalized = min(1, max(0, (20 * log10(max(rms, 1e-6)) + 50) / 50))
        DispatchQueue.main.async {
            self.level = self.level * 0.6 + normalized * 0.4
            self.levels.removeFirst()
            self.levels.append(self.level)
        }
    }

    /// 16-bit PCM WAV, the format every provider accepts.
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
