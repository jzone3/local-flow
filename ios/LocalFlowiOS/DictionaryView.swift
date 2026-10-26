import SwiftUI

/// The same dictionary as the Mac app: one term per line, "heard => Correct" for replacements.
struct DictionaryView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("vocabulary") private var text = Vocabulary.defaultText
    @AppStorage("dictionaryPacks") private var packsRaw = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .font(.body.monospaced())
                        .frame(minHeight: 260)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } footer: {
                    Text("Names and words you want spelled your way. One per line.")
                }
                Section("Add words for your field") {
                    ForEach(VocabularyPack.all) { pack in
                        Toggle(pack.name, isOn: binding(for: pack.id))
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .windowBackground()
            .navigationTitle("Dictionary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private var packs: Set<String> { Set(packsRaw.split(separator: ",").map(String.init)) }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(get: { packs.contains(id) }, set: { on in
            let before = packs
            var after = before
            if on { after.insert(id) } else { after.remove(id) }
            text = VocabularyPack.apply(selected: after, previouslySelected: before, to: text)
            packsRaw = VocabularyPack.all.map(\.id).filter { after.contains($0) }.joined(separator: ",")
        })
    }
}
