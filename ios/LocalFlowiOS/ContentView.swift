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
    // One size for every state, so the bar never jumps.
    static let size = CGSize(width: 340, height: 64)

    var body: some View {
        content
            .frame(height: Self.rowHeight)
            .frame(width: Self.size.width, height: Self.size.height)
            .background(Capsule().fill(Color.black))
            .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
            .environment(\.colorScheme, .dark)
            .scaleEffect(pressing ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: pressing)
            .animation(.spring(duration: 0.3), value: dictation.phase)
            .frame(width: Self.size.width, height: Self.size.height)
            .overlay(PressArea { down in
                if down {
                    guard !pressing, dictation.phase != .transcribing else { return }
                    pressing = true
                    dictation.pressBegan()
                } else if pressing {
                    pressing = false
                    dictation.pressEnded()
                }
            })
            .onReceive(NotificationCenter.default.publisher(for: ReleaseRecognizer.allTouchesEnded)) { _ in
                guard pressing else { return }
                pressing = false
                dictation.pressEnded()
            }
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

/// Touch down on the bar, from UIKit. SwiftUI swaps this view for a new one when listening starts, so the original
/// view never hears the finger lift; the release comes from `ReleaseRecognizer` on the window instead.
private struct PressArea: UIViewRepresentable {
    var onChange: (Bool) -> Void

    func makeUIView(context: Context) -> TouchView { TouchView() }
    func updateUIView(_ view: TouchView, context: Context) { view.onChange = onChange }

    final class TouchView: UIView {
        var onChange: (Bool) -> Void = { _ in }

        override func didMoveToWindow() {
            guard let window, !(window.gestureRecognizers ?? []).contains(where: { $0 is ReleaseRecognizer }) else { return }
            window.addGestureRecognizer(ReleaseRecognizer())
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { onChange(true) }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { onChange(false) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { onChange(false) }
    }
}

/// Watches every touch in the window without ever recognizing (so it never blocks anything) and posts when the
/// last finger lifts.
final class ReleaseRecognizer: UIGestureRecognizer {
    static let allTouchesEnded = Notification.Name("LocalFlowAllTouchesEnded")

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesEnded = false
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { finish(event) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { finish(event) }

    private func finish(_ event: UIEvent) {
        let lifted = event.allTouches?.allSatisfy { $0.phase == .ended || $0.phase == .cancelled } ?? true
        guard lifted else { return }
        NotificationCenter.default.post(name: Self.allTouchesEnded, object: nil)
        state = .failed
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
