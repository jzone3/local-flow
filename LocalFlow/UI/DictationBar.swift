import AppKit
import Combine
import SwiftUI

/// The floating pill at the bottom of the screen. Liquid Glass on macOS 26, frosted material before that.
final class DictationBarPanel: NSPanel {
    private var resize: AnyCancellable?
    private var hideGeneration = 0

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 72),
                   styleMask: [.borderless, .nonactivatingPanel, .hudWindow], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        alphaValue = 0
    }

    func attach(recorder: AudioRecorder, controller: DictationController) {
        contentView = NSHostingView(rootView: DictationBarView(recorder: recorder, controller: controller))
        // fittingSize lags one run-loop turn behind a SwiftUI state change, so re-fit after each one;
        // otherwise the pill keeps the size it had when it first appeared and the label gets cut off.
        resize = controller.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { if self?.isVisible == true { self?.position() } }
                // …and once more after the spring animation has settled, since fittingSize mid-animation is too small.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { if self?.isVisible == true { self?.position() } }
            }
    }

    func show() {
        hideGeneration += 1   // a hide() still fading out must not order the panel out from under us
        position()
        if !isVisible { orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            animator().alphaValue = 1
        }
    }

    func hide() {
        hideGeneration += 1
        let generation = hideGeneration
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, generation == hideGeneration, alphaValue == 0 else { return }
            orderOut(nil)
        })
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = contentView?.fittingSize ?? NSSize(width: 360, height: 72)
        setContentSize(size)
        setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 28))
    }
}

struct DictationBarView: View {
    @ObservedObject var recorder: AudioRecorder
    @ObservedObject var controller: DictationController

    var body: some View {
        content
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(minWidth: 220, maxWidth: 560)
            .modifier(GlassBackground())
            .padding(14)
            .animation(.spring(duration: 0.3), value: controller.state)
    }

    @ViewBuilder
    private var content: some View {
        switch controller.state {
        case .listening:
            HStack(spacing: 14) {
                Circle().fill(.red).frame(width: 9, height: 9)
                    .overlay(Circle().stroke(.red.opacity(0.4), lineWidth: 6).scaleEffect(1 + CGFloat(recorder.level)))
                Waveform(levels: recorder.levels)
                    .frame(width: 150, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(controller.handsFree ? "Listening · tap \(AppSettings.shared.hotkey.displayName) to stop" : "Listening")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(.primary)
                    Label { Text(AudioInputDevice.current.name) } icon: { Icon("mic", size: 10) }
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        case .transcribing:
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("Transcribing…").font(.system(size: 13, weight: .medium))
            }
        case .done:
            HStack(spacing: 10) {
                Icon("warning", size: 16).foregroundStyle(.orange)
                Text(controller.lastWarning ?? "Pasted").font(.system(size: 13)).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .failed(let message):
            HStack(spacing: 10) {
                Icon("x-circle", size: 16).foregroundStyle(.red)
                Text(message).font(.system(size: 13)).lineLimit(3)
            }
        case .idle:
            EmptyView()
        }
    }
}

/// `glassEffect` is a macOS 26 API; older systems get the closest thing, a thin material capsule.
struct GlassBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
        }
    }
}

struct Waveform: View {
    let levels: [Float]

    var body: some View {
        GeometryReader { geo in
            let count = levels.count
            let gap: CGFloat = 3
            let width = max(2, (geo.size.width - gap * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .center, spacing: gap) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(.primary.opacity(0.85))
                        .frame(width: width, height: max(3, CGFloat(level) * geo.size.height))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .animation(.linear(duration: 0.08), value: levels)
    }
}
