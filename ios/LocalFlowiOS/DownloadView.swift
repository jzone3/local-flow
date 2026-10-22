import SwiftUI

/// First launch: fetch the speech model once.
struct DownloadView: View {
    @EnvironmentObject var models: ModelStore

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "waveform").font(.system(size: 56, weight: .semibold))
            Text("Local Flow").font(.largeTitle.bold())
            Text("Dictation that stays on your iPhone. First it needs the speech model (\(ModelStore.sizeText)). It downloads once and never leaves this phone.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            if let progress = models.progress {
                ProgressView(value: progress)
                Text("\(Int(progress * 100))% · keep Local Flow open")
                    .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                Button("Cancel") { models.cancel() }
            } else {
                if let error = models.error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                Button { models.download() } label: {
                    Text("Download model").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Text("Whisper large-v3-turbo · from Hugging Face").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(32)
        .onChange(of: models.progress != nil) { _, downloading in
            UIApplication.shared.isIdleTimerDisabled = downloading
        }
    }
}
