import SwiftUI

/// First launch: fetch the speech model once. Laid out like the Mac setup window's model step.
struct DownloadView: View {
    @EnvironmentObject var models: ModelStore

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                AppIconImage()
                SetupHeader(title: "Download a local model",
                            subtitle: "Whisper runs on your iPhone and audio never leaves it.")
                VStack(alignment: .leading, spacing: 0) {
                    SetupRow(icon: "waveform", "Classic", "Whisper large-v3-turbo · \(ModelStore.sizeText)") {
                        if models.progress == nil, models.isDownloaded == false {
                            Icon("download", size: 18).foregroundStyle(.secondary)
                        }
                    }
                    if let progress = models.progress {
                        RowDivider()
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: progress)
                            Text("\(Int(progress * 100))% · keep Local Flow open")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 13)
                    }
                }
                .card()
                Group {
                    if let error = models.error {
                        Text(error).foregroundStyle(.red)
                    } else {
                        Text("Downloads once from Hugging Face. Wi‑Fi is best.").foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.top, 56)
        }
        .safeAreaInset(edge: .bottom) {
            Group {
                if models.progress != nil {
                    Button { models.cancel() } label: { Text("Cancel").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                } else {
                    Button { models.download() } label: { Text("Download").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .windowBackground()
        .onChange(of: models.progress != nil) { _, downloading in
            UIApplication.shared.isIdleTimerDisabled = downloading
        }
    }
}
