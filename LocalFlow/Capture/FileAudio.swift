import AVFoundation
import UniformTypeIdentifiers

/// Pulls the audio out of a file the user hands us (audio or video) as 16 kHz mono samples, the same shape the
/// microphone produces, so the rest of the pipeline doesn't know the difference.
enum FileAudio {
    static let types: [UTType] = [.audio, .movie]

    static func isSupported(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return types.contains { type.conforms(to: $0) }
    }

    static func samples(from url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw NSError(domain: "LocalFlow.File", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(url.lastPathComponent) has no audio."])
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioRecorder.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? NSError(domain: "LocalFlow.File", code: 2, userInfo: [NSLocalizedDescriptionKey: "Couldn't read \(url.lastPathComponent)."])
        }
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var bytes = [UInt8](repeating: 0, count: length)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &bytes)
            bytes.withUnsafeBytes { raw in samples.append(contentsOf: raw.bindMemory(to: Float.self)) }
        }
        if reader.status == .failed, let error = reader.error { throw error }
        return samples
    }
}
