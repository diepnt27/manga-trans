import Foundation

/// Một chương đã đọc gần đây (để "Đọc tiếp" và gợi ý truyện tương tự).
struct ReadingEntry: Codable, Identifiable, Hashable {
    var mangaTitle: String
    var pageTitle: String
    var url: String
    var host: String
    var date: Date

    var id: String { host + "|" + mangaTitle.lowercased() }
}

/// Trang đọc truyện hiện trên trang Tab mới.
struct ReadingSite: Codable, Identifiable, Hashable {
    var name: String
    var url: String
    /// Địa chỉ tìm kiếm của trang, `%@` là tên truyện; không có thì tìm bằng Google trong trang đó.
    var searchTemplate: String?

    var id: String { host }

    var host: String { Self.host(of: url) }

    func searchURL(for title: String) -> String {
        let query = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title
        if let searchTemplate { return searchTemplate.replacingOccurrences(of: "%@", with: query) }
        return DiscoverStore.googleSearch("site:\(host) \(title)")
    }

    static func host(of url: String) -> String {
        let host = URL(string: url)?.host ?? url
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Trang đọc truyện chính thức (miễn phí hoặc có chương miễn phí).
    static let defaults: [ReadingSite] = [
        ReadingSite(name: "MANGA Plus", url: "https://mangaplus.shueisha.co.jp/updates"),
        ReadingSite(name: "Webtoon", url: "https://www.webtoons.com/en/",
                    searchTemplate: "https://www.webtoons.com/en/search?keyword=%@"),
        ReadingSite(name: "MangaDex", url: "https://mangadex.org", searchTemplate: "https://mangadex.org/search?q=%@"),
        ReadingSite(name: "Tapas", url: "https://tapas.io", searchTemplate: "https://tapas.io/search?q=%@"),
        ReadingSite(name: "K MANGA", url: "https://kmanga.kodansha.com"),
        ReadingSite(name: "Comikey", url: "https://comikey.com"),
    ]
}

/// Dữ liệu của trang Tab mới: lịch sử đọc, trang đọc truyện, thể loại yêu thích. Chỉ lưu trên máy.
@MainActor
final class DiscoverStore: ObservableObject {
    static let shared = DiscoverStore()

    @Published private(set) var history: [ReadingEntry] = []
    @Published private(set) var customSites: [ReadingSite] = []
    @Published private(set) var hiddenHosts: Set<String> = []
    @Published var favoriteGenres: [String] = [] {
        didSet { defaults.set(favoriteGenres, forKey: Keys.genres) }
    }
    @Published var origin: MangaOrigin = .all {
        didSet { defaults.set(origin.rawValue, forKey: Keys.origin) }
    }

    private let defaults: UserDefaults
    private static let historyLimit = 60

    private enum Keys {
        static let history = "discoverHistory"
        static let sites = "discoverSites"
        static let hidden = "discoverHiddenHosts"
        static let genres = "discoverGenres"
        static let origin = "discoverOrigin"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        history = (defaults.data(forKey: Keys.history)).flatMap { try? JSONDecoder().decode([ReadingEntry].self, from: $0) } ?? []
        customSites = (defaults.data(forKey: Keys.sites)).flatMap { try? JSONDecoder().decode([ReadingSite].self, from: $0) }
            ?? ReadingSite.defaults
        hiddenHosts = Set(defaults.stringArray(forKey: Keys.hidden) ?? [])
        favoriteGenres = defaults.stringArray(forKey: Keys.genres) ?? []
        origin = MangaOrigin(rawValue: defaults.string(forKey: Keys.origin) ?? "") ?? .all
    }

    /// Trang hay đọc (theo lịch sử) đứng trước, sau đó là trang bạn thêm / trang mặc định.
    var sites: [ReadingSite] {
        var counts: [String: Int] = [:]
        history.forEach { counts[$0.host, default: 0] += 1 }
        let frequent = counts.sorted { $0.value > $1.value }.compactMap { host, _ -> ReadingSite? in
            guard let entry = history.first(where: { $0.host == host }) else { return nil }
            return ReadingSite(name: host, url: URL(string: entry.url).map { "\($0.scheme ?? "https")://\($0.host ?? host)" } ?? entry.url)
        }
        var seen = Set<String>()
        return (frequent + customSites).filter { !hiddenHosts.contains($0.host) && seen.insert($0.host).inserted }
    }

    /// Truyện vừa đọc, mỗi bộ một mục.
    var continueReading: [ReadingEntry] { Array(history.prefix(12)) }

    /// Tên các bộ truyện đọc gần đây nhất (để gợi ý truyện tương tự).
    func recentTitles(limit: Int) -> [String] {
        var seen = Set<String>()
        return history.map(\.mangaTitle).filter { seen.insert($0.lowercased()).inserted }.prefix(limit).map { $0 }
    }

    /// Gọi khi trang tải xong: trang chương truyện thì ghi vào lịch sử.
    func recordVisit(pageTitle: String, url: String) {
        guard Self.isChapterPage(title: pageTitle, url: url), let name = Self.mangaName(fromTitle: pageTitle) else { return }
        let entry = ReadingEntry(mangaTitle: name, pageTitle: pageTitle, url: url, host: ReadingSite.host(of: url), date: Date())
        history.removeAll { $0.id == entry.id }
        history.insert(entry, at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
        saveHistory()
    }

    func removeHistory(_ entry: ReadingEntry) {
        history.removeAll { $0.id == entry.id }
        saveHistory()
    }

    func clearHistory() {
        history = []
        saveHistory()
    }

    /// Thêm trang đọc truyện từ địa chỉ người dùng nhập; trả về `false` nếu địa chỉ không hợp lệ.
    @discardableResult
    func addSite(_ input: String) -> Bool {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.lowercased().hasPrefix("http") { text = "https://" + text }
        guard let url = URL(string: text), let host = url.host, host.contains(".") else { return false }
        let site = ReadingSite(name: ReadingSite.host(of: text), url: "\(url.scheme ?? "https")://\(host)")
        hiddenHosts.remove(site.host)
        customSites.removeAll { $0.host == site.host }
        customSites.insert(site, at: 0)
        saveSites()
        return true
    }

    func hideSite(_ site: ReadingSite) {
        hiddenHosts.insert(site.host)
        customSites.removeAll { $0.host == site.host }
        saveSites()
    }

    func restoreDefaultSites() {
        hiddenHosts = []
        customSites = ReadingSite.defaults
        saveSites()
    }

    func toggleGenre(_ name: String) {
        if let index = favoriteGenres.firstIndex(of: name) {
            favoriteGenres.remove(at: index)
        } else {
            favoriteGenres.append(name)
        }
    }

    private func saveHistory() {
        defaults.set(try? JSONEncoder().encode(history), forKey: Keys.history)
    }

    private func saveSites() {
        defaults.set(try? JSONEncoder().encode(customSites), forKey: Keys.sites)
        defaults.set(Array(hiddenHosts), forKey: Keys.hidden)
    }

    // MARK: - Nhận biết trang chương truyện

    private static let chapterPattern = try! NSRegularExpression(
        pattern: "\\b(chapter|chap|ch\\.|chương|chuong|episode|ep\\.?)\\s*#?\\d+", options: [.caseInsensitive])

    nonisolated static func isChapterPage(title: String, url: String) -> Bool {
        let range = NSRange(title.startIndex..., in: title)
        if chapterPattern.firstMatch(in: title, range: range) != nil { return true }
        let path = URL(string: url)?.path.lowercased() ?? ""
        return ["chapter", "chuong", "episode", "/ch-", "/viewer"].contains { path.contains($0) } && !title.isEmpty
    }

    /// Tên bộ truyện từ tiêu đề trang chương: "Read Nano Machine Chapter 31 Online - MangaRead" → "Nano Machine".
    nonisolated static func mangaName(fromTitle title: String) -> String? {
        let parts = title.components(separatedBy: CharacterSet(charactersIn: "|–—"))
            .flatMap { $0.components(separatedBy: " - ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        for (index, part) in parts.enumerated() {
            let range = NSRange(part.startIndex..., in: part)
            guard let match = chapterPattern.firstMatch(in: part, range: range),
                  let matchRange = Range(match.range, in: part) else { continue }
            let before = clean(String(part[..<matchRange.lowerBound]))
            if !before.isEmpty { return before }
            if index > 0 { return clean(parts[index - 1]) }
        }
        // Không có chữ "Chapter" kèm tên: lấy phần đầu tiên không phải số chương.
        let name = parts.first { chapterPattern.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) == nil }
        let cleaned = name.map(clean) ?? ""
        return cleaned.isEmpty ? nil : cleaned
    }

    private nonisolated static func clean(_ text: String) -> String {
        var result = text.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",:-")))
        for prefix in ["Read ", "Đọc truyện ", "Đọc "] where result.lowercased().hasPrefix(prefix.lowercased()) {
            result = String(result.dropFirst(prefix.count))
        }
        for suffix in [" Online", " Manga", " Manhwa", " Manhua", " English"] where result.lowercased().hasSuffix(suffix.lowercased()) {
            result = String(result.dropLast(suffix.count))
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    nonisolated static func googleSearch(_ query: String) -> String {
        var components = URLComponents(string: "https://www.google.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url?.absoluteString ?? "https://www.google.com"
    }
}
