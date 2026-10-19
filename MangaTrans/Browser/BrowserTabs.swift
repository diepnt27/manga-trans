import Foundation

/// Danh sách tab trình duyệt — mỗi tab một truyện, giữ riêng trang, vị trí đọc, bản dịch đang hiện.
@MainActor
final class BrowserTabs: ObservableObject {
    /// Mỗi tab là một trình duyệt riêng (khá tốn RAM) → giới hạn số tab.
    static let maxTabs = 6

    @Published private(set) var tabs: [BrowserModel] = []
    @Published private(set) var selectedID: UUID

    private let translation: TranslationService
    private let urlsKey = "browserTabURLs"
    private let selectedKey = "browserSelectedTab"

    init(translation: TranslationService) {
        self.translation = translation
        let defaults = UserDefaults.standard
        // Lần đầu (bản cũ chỉ có 1 tab): mở lại trang đọc dở.
        var urls = defaults.stringArray(forKey: urlsKey)
            ?? [defaults.string(forKey: BrowserModel.lastURLKey) ?? BrowserModel.homeURL]
        if urls.isEmpty { urls = [BrowserModel.homeURL] }
        urls = Array(urls.prefix(Self.maxTabs))

        let placeholder = UUID()
        selectedID = placeholder
        tabs = urls.map(makeTab)
        let index = min(max(0, defaults.integer(forKey: selectedKey)), tabs.count - 1)
        selectedID = tabs[index].id
    }

    var current: BrowserModel {
        tabs.first { $0.id == selectedID } ?? tabs[0]
    }

    var canAddTab: Bool { tabs.count < Self.maxTabs }

    func newTab(url: String? = nil) {
        guard canAddTab else { return }
        current.captureThumbnail()
        let tab = makeTab(url ?? BrowserModel.homeURL)
        tabs.append(tab)
        selectedID = tab.id
        SpeechReader.shared.stop()
        save()
    }

    func select(_ id: UUID) {
        guard id != selectedID, tabs.contains(where: { $0.id == id }) else { return }
        current.captureThumbnail()
        SpeechReader.shared.stop()
        selectedID = id
        save()
    }

    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].close()
        tabs.remove(at: index)
        if tabs.isEmpty {
            let tab = makeTab(BrowserModel.homeURL)
            tabs = [tab]
            selectedID = tab.id
        } else if selectedID == id {
            selectedID = tabs[min(index, tabs.count - 1)].id
        }
        save()
    }

    /// Dữ liệu duyệt web dùng chung cho mọi tab.
    func clearBrowsingData() {
        current.clearBrowsingData()
    }

    private func makeTab(_ url: String) -> BrowserModel {
        let tab = BrowserModel(translation: translation, initialURL: url)
        tab.onPageFinished = { [weak self] in self?.save() }
        return tab
    }

    private func save() {
        let urls = tabs.map { $0.currentURL.isEmpty ? ($0.initialURL ?? BrowserModel.homeURL) : $0.currentURL }
        UserDefaults.standard.set(urls, forKey: urlsKey)
        UserDefaults.standard.set(tabs.firstIndex { $0.id == selectedID } ?? 0, forKey: selectedKey)
    }
}
