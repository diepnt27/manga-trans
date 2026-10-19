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
    @AppStorage(SettingsKey.translationConsentAsked, store: AppGroup.defaults) private var consentAsked = false
    @AppStorage(SettingsKey.translationConsent, store: AppGroup.defaults) private var consent = false

    var body: some View {
        TabView(selection: $selection) {
            HomeView(pip: coordinator.pip)
                .tabItem { Label("Trang chủ", systemImage: "house") }
                .tag(0)
            BrowserView(tabs: coordinator.tabs)
                .tabItem { Label("Trình duyệt", systemImage: "safari") }
                .tag(1)
            SettingsView()
                .tabItem { Label("Cài đặt", systemImage: "gearshape") }
                .tag(2)
        }
        .fullScreenCover(isPresented: Binding(get: { !consentAsked }, set: { _ in })) {
            ConsentView { accepted in
                consent = accepted
                consentAsked = true
            }
        }
    }
}

/// Hỏi ý người dùng trước khi gửi chữ cho dịch vụ bên ngoài (quy định 5.1.2 của App Store).
struct ConsentView: View {
    let onDecide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            Image(systemName: "text.bubble")
                .font(.system(size: 44))
                .foregroundStyle(.blue)
            Text("Dịch bằng dịch vụ bên ngoài")
                .font(.title2.bold())
            VStack(alignment: .leading, spacing: 10) {
                Text("Để dịch, app nhận dạng chữ tiếng Anh trên trang truyện ngay trên máy, rồi gửi **chỉ phần chữ đó** tới bộ dịch bạn chọn (Google, Gemini hoặc DeepSeek). Hình ảnh không được gửi đi.")
                Text("App không thu thập, không lưu trữ trên máy chủ và không bán dữ liệu của bạn. Bạn có thể đổi lựa chọn bất cứ lúc nào trong Cài đặt → Quyền riêng tư.")
            }
            .foregroundStyle(.secondary)
            Link("Đọc chính sách quyền riêng tư", destination: AppLinks.privacyPolicy)
            Spacer()
            Button { onDecide(true) } label: {
                Text("Đồng ý và tiếp tục")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.blue, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
            }
            Button("Không, để sau") { onDecide(false) }
                .frame(maxWidth: .infinity)
        }
        .padding(24)
        .background(Color.black.ignoresSafeArea())
        .interactiveDismissDisabled()
    }
}

enum AppLinks {
    static let privacyPolicy = URL(string: "https://github.com/diepnt27/manga-trans/blob/main/docs/PRIVACY.md")!
}

enum AppEdition {
    /// Bản Lite không kèm Broadcast Extension → không có chế độ quay màn hình, chỉ tốn 1 App ID khi sideload.
    static let hasScreenTranslation: Bool = {
        guard let plugins = Bundle.main.builtInPlugInsURL else { return false }
        return FileManager.default.fileExists(atPath: plugins.appendingPathComponent("BroadcastExt.appex").path)
    }()
}
