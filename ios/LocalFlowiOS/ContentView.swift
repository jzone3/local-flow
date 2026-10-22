import SwiftUI

struct ContentView: View {
    @EnvironmentObject var dictation: DictationModel
    @State private var showSetup = false
    @State private var showDictionary = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                TranscriptArea()
                    .frame(maxHeight: .infinity)
                Waveform(recorder: dictation.recorder, active: dictation.isListening)
                    .frame(height: 44)
                    .padding(.horizontal, 40)
                RecordButton()
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 12)
            }
            .padding(.horizontal, 24)
            .navigationTitle("Local Flow")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showDictionary = true } label: { Image(systemName: "book") }
                        .accessibilityLabel("Dictionary")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSetup = true } label: { Image(systemName: "keyboard") }
                        .accessibilityLabel("Keyboard setup")
                }
            }
            .sheet(isPresented: $showSetup) { SetupView() }
            .sheet(isPresented: $showDictionary) { DictionaryView() }
        }
    }

    private var caption: String {
        switch dictation.phase {
        case .listening: return "Tap to stop. Or let go if you're holding."
        case .transcribing: return "Turning speech into text on this iPhone…"
        default: return "Tap to start, tap to stop. Or hold to talk."
        }
    }
}

private struct TranscriptArea: View {
    @EnvironmentObject var dictation: DictationModel

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            switch dictation.phase {
            case .listening:
                Text("Listening…").font(.title2.weight(.semibold))
            case .transcribing:
                ProgressView()
                Text("Transcribing…").font(.headline).foregroundStyle(.secondary)
            case .failed(let message):
                Text(message).font(.headline).multilineTextAlignment(.center)
            case .done:
                ScrollView {
                    Text(dictation.transcript)
                        .font(.title3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 280)
                Label("Copied", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                if dictation.cameFromKeyboard {
                    Text("Tap ◀ in the top-left to go back.\nThen tap Insert on the keyboard, or paste.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                #if DEBUG
                if let peak = dictation.peakMemoryMB {
                    Text("Peak memory \(peak) MB").font(.caption2).foregroundStyle(.tertiary)
                }
                #endif
            case .idle:
                Text("Speak, and the text lands on your clipboard.")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer(minLength: 0)
        }
    }
}

struct RecordButton: View {
    @EnvironmentObject var dictation: DictationModel
    @State private var pressing = false

    var body: some View {
        let listening = dictation.isListening
        ZStack {
            Circle()
                .fill(Color.primary)
                .frame(width: 132, height: 132)
            if listening {
                RoundedRectangle(cornerRadius: 8).fill(Color(.systemBackground)).frame(width: 40, height: 40)
            } else {
                Image(systemName: "mic.fill").font(.system(size: 48, weight: .semibold)).foregroundStyle(Color(.systemBackground))
            }
        }
        .overlay(Circle().stroke(Color.primary.opacity(listening ? 0.25 : 0), lineWidth: 10).padding(-12))
        .scaleEffect(pressing ? 0.94 : 1)
        .animation(.easeOut(duration: 0.12), value: pressing)
        .opacity(dictation.phase == .transcribing ? 0.3 : 1)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressing else { return }
                    pressing = true
                    dictation.pressBegan()
                }
                .onEnded { _ in
                    pressing = false
                    dictation.pressEnded()
                }
        )
        .accessibilityElement()
        .accessibilityLabel(listening ? "Stop" : "Start dictation")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { dictation.toggle() }
    }
}

struct Waveform: View {
    @ObservedObject var recorder: Recorder
    let active: Bool

    private var levels: [Float] { recorder.levels }

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(Color.primary)
                    .frame(width: 4, height: active ? max(4, CGFloat(levels[i]) * 44) : 4)
            }
        }
        .opacity(active ? 1 : 0.15)
        .animation(.linear(duration: 0.08), value: levels)
        .accessibilityHidden(true)
    }
}
