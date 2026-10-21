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
    private var monitorGain = AutoGain()
    private var monitoring = false
    private var resumeMonitoring = false
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

    /// True once the user has answered the system prompt with "Don't Allow"; only System Settings can change it then.
    static var isDenied: Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        return status == .denied || status == .restricted
    }

    func start() throws {
        gain.reset()
        guard !isRecording else { return }
        resumeMonitoring = monitoring
        stopMonitoring()
        samples = []
        let input = engine.inputNode
        selectDevice(on: input)
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(domain: "LocalFlow.Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone is available."])
        }
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
        engine.prepare()
        try engine.start()
        isRecording = true
        startedAt = Date()
    }

    /// Settings mic test: runs the engine with a tap that only measures level. Stops itself when a real
    /// recording starts and restarts when the chosen device changes.
    func startMonitoring() {
        monitorGain.reset()
        guard !monitoring, !isRecording, Self.hasPermission else { return }
        monitoring = true
        let input = engine.inputNode
        selectDevice(on: input)
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { monitoring = false; return }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self, let mono = Self.mixedToMono(buffer), let data = mono.floatChannelData, mono.frameLength > 0 else { return }
            let chunk = UnsafeBufferPointer(start: data[0], count: Int(mono.frameLength))
            let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count))
            DispatchQueue.main.async {
                let normalized = self.monitorGain.level(rms: rms)
                self.monitorLevel = self.monitorLevel * 0.5 + normalized * 0.5
            }
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
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        if resumeMonitoring { resumeMonitoring = false; DispatchQueue.main.async { self.startMonitoring() } }
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
