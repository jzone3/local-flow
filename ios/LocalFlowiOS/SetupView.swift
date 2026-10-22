import SwiftUI

/// How to turn on the keyboard. Shown once after the model downloads, and from the keyboard button.
struct SetupView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Step(number: 1, text: "Open Settings → General → Keyboard → Keyboards.")
                    Step(number: 2, text: "Tap Add New Keyboard… and pick Local Flow.")
                    Step(number: 3, text: "Tap Local Flow and turn on Allow Full Access.")
                    Step(number: 4, text: "In any app, hold 🌐 and pick Local Flow.")
                } footer: {
                    Text("Full Access only lets the keyboard read your last transcript from this app. Nothing is sent anywhere.")
                }
                Section {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                } footer: {
                    Text("Shortcut: Settings → Local Flow → Keyboards has both switches.")
                }
                Section("Using it") {
                    Text("Tap Dictate on the keyboard. Local Flow opens and listens. Tap stop, then tap ◀ in the top-left to go back and tap Insert.")
                }
            }
            .navigationTitle("Turn on the keyboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private struct Step: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)").font(.headline).monospacedDigit().frame(width: 20)
            Text(text)
        }
    }
}
