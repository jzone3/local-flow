import SwiftUI

/// How to turn on the keyboard, laid out like a Mac setup step. Shown once after the model downloads, and from the
/// keyboard button.
struct SetupView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 26) {
                    SetupHeader(title: "Turn on the keyboard", subtitle: "So you can dictate from any app.", icon: "keyboard")
                    VStack(spacing: 0) {
                        SetupRow(step: 1, "Open Settings", "General → Keyboard → Keyboards.")
                        RowDivider()
                        SetupRow(step: 2, "Add Local Flow", "Tap Add New Keyboard… and pick Local Flow.")
                        RowDivider()
                        SetupRow(step: 3, "Allow Full Access", "Tap Local Flow and turn it on.")
                        RowDivider()
                        SetupRow(step: 4, "Switch to it", "In any app, hold 🌐 and pick Local Flow.")
                    }
                    .card()
                    VStack(spacing: 0) {
                        SetupRow(icon: "mic", "Dictate", "Tap Dictate on the keyboard. Local Flow opens and listens.")
                        RowDivider()
                        SetupRow(icon: "check-circle", "Go back", "Tap the bar to stop. You go back on your own. Tap Insert.")
                        RowDivider()
                        SetupRow(icon: "lock", "Nothing is sent", "Full Access only lets the keyboard read your last transcript from this app.")
                    }
                    .card()
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                } label: {
                    Text("Open Settings").frame(maxWidth: .infinity).foregroundStyle(Color(.systemBackground))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Color.window)
            }
            .windowBackground()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
