import SwiftUI

@main
struct LocalFlowApp: App {
    @StateObject private var dictation = DictationModel()
    @StateObject private var models = ModelStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(dictation)
                .environmentObject(models)
                .onOpenURL { dictation.handle($0, modelReady: models.isDownloaded) }
                .onChange(of: scenePhase) { _, phase in dictation.scenePhaseChanged(phase) }
                .tint(.primary)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var models: ModelStore
    @EnvironmentObject var dictation: DictationModel
    @AppStorage("keyboardSetupShown") private var keyboardSetupShown = false
    @State private var showSetup = false

    var body: some View {
        Group {
            if models.isDownloaded {
                ContentView()
            } else {
                DownloadView()
            }
        }
        .onChange(of: models.isDownloaded) { _, ready in
            guard ready else { return }
            WhisperEngine.shared.preload()
            if !keyboardSetupShown { keyboardSetupShown = true; showSetup = true }
            dictation.startIfRequested()
        }
        .onAppear { if models.isDownloaded { WhisperEngine.shared.preload() } }
        .sheet(isPresented: $showSetup) { SetupView() }
    }
}
