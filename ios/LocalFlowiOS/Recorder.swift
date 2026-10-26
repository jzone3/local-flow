import AVFoundation

/// Records the microphone as 16 kHz mono floats (what Whisper wants) and publishes levels for the waveform.
final class Recorder: ObservableObject {
    static let sampleRate: Double = 16_000

    @Published private(set) var levels: [Float] = Array(repeating: 0, count: 28)

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()
    private var gain = AutoGain()
    private(set) var isRecording = false

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start() throws {
        guard !isRecording else { return }
        gain.reset()
        lock.lock(); samples = []; lock.unlock()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw DictationError("No microphone is available.") }
        let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false)!
        converter = AVAudioConverter(from: format, to: output)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.consume(buffer, output: output)
        }
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Stops and returns everything captured since `start()`.
    func stop() -> [Float] {
        guard isRecording else { return [] }
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        lock.lock(); let captured = samples; samples = []; lock.unlock()
        DispatchQueue.main.async { self.levels = Array(repeating: 0, count: self.levels.count) }
        return captured
    }

    private func append(_ chunk: [Float]) {
        lock.lock(); samples.append(contentsOf: chunk); lock.unlock()
        let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(max(1, chunk.count)))
        DispatchQueue.main.async {
            let level = self.gain.level(rms: rms)
            self.levels.removeFirst()
            self.levels.append(level)
        }
    }

    private func consume(_ buffer: AVAudioPCMBuffer, output: AVAudioFormat) {
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * output.sampleRate / buffer.format.sampleRate) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.floatChannelData, out.frameLength > 0 else { return }
        append(Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength))))
    }
}
