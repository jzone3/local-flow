import SwiftUI

struct ContentView: View {
    @EnvironmentObject var dictation: DictationModel
    @State private var showSetup = false
    @State private var showDictionary = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    StatusArea()
                        .padding(.horizontal, 24)
                        .padding(.top, 24)
                        .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
                ListeningBar(recorder: dictation.recorder)
                    .padding(.top, 12)
                    .padding(.bottom, 20)
            }
            .windowBackground()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showDictionary = true } label: { Icon("book", size: 20) }
                        .accessibilityLabel("Dictionary")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSetup = true } label: { Icon("keyboard", size: 22) }
                        .accessibilityLabel("Keyboard setup")
                }
            }
            .sheet(isPresented: $showSetup) { SetupView() }
            .sheet(isPresented: $showDictionary) { DictionaryView() }
            .onChange(of: dictation.isListening) { _, listening in
                if listening { showSetup = false; showDictionary = false }
            }
        }
    }
}

/// Same heading layout as the Mac setup window, one per state.
private struct StatusArea: View {
    @EnvironmentObject var dictation: DictationModel

    var body: some View {
        VStack(spacing: 26) {
            switch dictation.phase {
            case .idle:
                AppIconImage()
                SetupHeader(title: "Local Flow", subtitle: "Tap the bar, talk, tap again.\nThe text lands on your clipboard.")
                VStack(spacing: 0) {
                    SetupRow(icon: "lock", "Private by default", "Whisper runs on your iPhone. Nothing leaves it.")
                    RowDivider()
                    SetupRow(icon: "hand", "Tap or hold", "Tap to start and stop, or hold to talk and let go.")
                    RowDivider()
                    SetupRow(icon: "keyboard", "Works in any app", "Tap Dictate on the Local Flow keyboard.")
                }
                .card()
            case .listening:
                SetupHeader(title: "Listening", subtitle: "Talk. Tap the bar when you're done,\nor let go if you're holding it.", icon: "mic")
            case .transcribing:
                SetupHeader(title: "Transcribing", subtitle: "On this iPhone. Nothing leaves it.", icon: "waveform")
            case .failed(let message):
                SetupHeader(title: "That didn't work", subtitle: message, icon: "x-circle")
            case .done:
                SetupHeader(title: "Copied", subtitle: dictation.cameFromKeyboard
                            ? "Tap ◀ in the top-left to go back.\nThen tap Insert on the keyboard, or paste."
                            : "Paste it anywhere.", icon: "check-circle")
                Text(dictation.transcript)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(16)
                    .card(cornerRadius: 12)
                #if DEBUG
                if let peak = dictation.peakMemoryMB {
                    Text("Peak memory \(peak) MB").font(.caption).foregroundStyle(.tertiary)
                }
                #endif
            }
        }
        .animation(.easeInOut(duration: 0.2), value: dictation.phase)
    }
}

/// The Mac app's listening bar, as the record button: a black pill with a red dot and a white waveform.
/// Tap to start / tap to stop, or hold to talk and let go to stop.
struct ListeningBar: View {
    @EnvironmentObject var dictation: DictationModel
    @ObservedObject var recorder: Recorder
    @State private var pressing = false

    // The Mac bar's sizes (24 pt row, 16/8 padding, 170 pt waveform) scaled up for a thumb.
    static let rowHeight: CGFloat = 32

    var body: some View {
        content
            .frame(height: Self.rowHeight)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(minWidth: 260)
            .background(Capsule().fill(Color.black))
            .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
            .environment(\.colorScheme, .dark)
            .scaleEffect(pressing ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: pressing)
            .animation(.spring(duration: 0.3), value: dictation.phase)
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressing, dictation.phase != .transcribing else { return }
                        pressing = true
                        dictation.pressBegan()
                    }
                    .onEnded { _ in
                        guard pressing else { return }
                        pressing = false
                        dictation.pressEnded()
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(dictation.isListening ? "Stop" : "Start dictation")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { dictation.toggle() }
    }

    @ViewBuilder
    private var content: some View {
        switch dictation.phase {
        case .listening:
            HStack(spacing: 14) {
                Circle().fill(.red).frame(width: 11, height: 11)
                    .overlay(Circle().stroke(.red.opacity(0.4), lineWidth: 7).scaleEffect(1 + CGFloat(recorder.levels.last ?? 0)))
                Waveform(levels: recorder.levels)
                    .frame(width: 170, height: Self.rowHeight)
                Text(pressing ? "Let go" : "Tap to stop")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        case .transcribing:
            HStack(spacing: 12) {
                ProgressView()
                Text("Transcribing…").font(.system(size: 15, weight: .medium))
            }
        default:
            HStack(spacing: 10) {
                Icon("mic", size: 18)
                Text("Tap or hold to talk").font(.system(size: 15, weight: .medium))
            }
        }
    }
}

/// The Mac bar's waveform: auto-gained levels as rounded bars.
struct Waveform: View {
    let levels: [Float]

    var body: some View {
        GeometryReader { geo in
            let count = levels.count
            let gap: CGFloat = 3
            let width = max(3, (geo.size.width - gap * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .center, spacing: gap) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(.primary.opacity(0.85))
                        .frame(width: width, height: max(4, min(1, CGFloat(level) * 1.2) * geo.size.height))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .animation(.linear(duration: 0.08), value: levels)
        .accessibilityHidden(true)
    }
}
