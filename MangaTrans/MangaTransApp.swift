import SwiftUI

@main
struct MangaTransApp: App {
    @StateObject private var coordinator = TranslationCoordinator()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(coordinator)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var coordinator: TranslationCoordinator

    // Bản Lite mở thẳng tab Trình duyệt.
    @State private var selection = AppEdition.hasScreenTranslation ? 0 : 1

    var body: some View {
        TabView(selection: $selection) {
            HomeView(pip: coordinator.pip)
                .tabItem { Label("Trang chủ", systemImage: "house") }
                .tag(0)
            BrowserView(model: coordinator.browser)
                .tabItem { Label("Trình duyệt", systemImage: "safari") }
                .tag(1)
            SettingsView()
                .tabItem { Label("Cài đặt", systemImage: "gearshape") }
                .tag(2)
        }
    }
}

enum AppEdition {
    /// Bản Lite không kèm Broadcast Extension → không có chế độ quay màn hình, chỉ tốn 1 App ID khi sideload.
    static let hasScreenTranslation: Bool = {
        guard let plugins = Bundle.main.builtInPlugInsURL else { return false }
        return FileManager.default.fileExists(atPath: plugins.appendingPathComponent("BroadcastExt.appex").path)
    }()
}
