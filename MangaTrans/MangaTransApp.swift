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

    var body: some View {
        TabView {
            HomeView(pip: coordinator.pip)
                .tabItem { Label("Trang chủ", systemImage: "house") }
            BrowserView(model: coordinator.browser)
                .tabItem { Label("Trình duyệt", systemImage: "safari") }
            SettingsView()
                .tabItem { Label("Cài đặt", systemImage: "gearshape") }
        }
    }
}
