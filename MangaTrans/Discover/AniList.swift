import Foundation

/// Một bộ truyện trong danh sách gợi ý (dữ liệu từ AniList).
struct MangaItem: Codable, Identifiable, Hashable {
    let id: Int
    let title: String
    let nativeTitle: String?
    let cover: URL?
    let genres: [String]
    /// Điểm trung bình 0–100.
    let score: Int?
    /// JP: manga, KR: manhwa, CN/TW: manhua.
    let country: String?
    let chapters: Int?
    let status: String?
    let summary: String?
    let siteURL: URL?

    var originLabel: String {
        switch country {
        case "KR": return "Manhwa"
        case "CN", "TW": return "Manhua"
        default: return "Manga"
        }
    }

    var statusLabel: String? {
        switch status {
        case "RELEASING": return "Đang ra"
        case "FINISHED": return "Hoàn thành"
        case "HIATUS": return "Tạm ngưng"
        case "NOT_YET_RELEASED": return "Sắp ra"
        case "CANCELLED": return "Đã huỷ"
        default: return nil
        }
    }
}

/// Lọc theo loại truyện.
enum MangaOrigin: String, CaseIterable, Identifiable {
    case all, manga, manhwa, manhua

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "Tất cả"
        case .manga: return "Manga"
        case .manhwa: return "Manhwa"
        case .manhua: return "Manhua"
        }
    }

    var countryCode: String? {
        switch self {
        case .all: return nil
        case .manga: return "JP"
        case .manhwa: return "KR"
        case .manhua: return "CN"
        }
    }
}

/// Thể loại (genre) và chủ đề (tag) của AniList mà người đọc có thể chọn làm sở thích.
struct MangaGenre: Hashable, Identifiable {
    let name: String
    let title: String
    let isTag: Bool

    var id: String { name }

    static let all: [MangaGenre] = [
        MangaGenre(name: "Action", title: "Hành động", isTag: false),
        MangaGenre(name: "Martial Arts", title: "Võ thuật", isTag: true),
        MangaGenre(name: "Fantasy", title: "Giả tưởng", isTag: false),
        MangaGenre(name: "Isekai", title: "Xuyên không", isTag: true),
        MangaGenre(name: "Reincarnation", title: "Chuyển sinh", isTag: true),
        MangaGenre(name: "Revenge", title: "Báo thù", isTag: true),
        MangaGenre(name: "Adventure", title: "Phiêu lưu", isTag: false),
        MangaGenre(name: "Romance", title: "Lãng mạn", isTag: false),
        MangaGenre(name: "Comedy", title: "Hài hước", isTag: false),
        MangaGenre(name: "Drama", title: "Kịch tính", isTag: false),
        MangaGenre(name: "Slice of Life", title: "Đời thường", isTag: false),
        MangaGenre(name: "Mystery", title: "Bí ẩn", isTag: false),
        MangaGenre(name: "Psychological", title: "Tâm lý", isTag: false),
        MangaGenre(name: "Horror", title: "Kinh dị", isTag: false),
        MangaGenre(name: "Thriller", title: "Giật gân", isTag: false),
        MangaGenre(name: "Supernatural", title: "Siêu nhiên", isTag: false),
        MangaGenre(name: "Sci-Fi", title: "Khoa học viễn tưởng", isTag: false),
        MangaGenre(name: "Sports", title: "Thể thao", isTag: false),
    ]

    static func title(for name: String) -> String {
        all.first { $0.name == name }?.title ?? name
    }
}

/// API GraphQL công khai của AniList (không cần key). Chỉ lấy truyện không dành cho người lớn.
/// Kết quả được lưu đệm 6 giờ (bộ nhớ + ổ đĩa) để trang Tab mới mở ra là có ngay.
enum AniList {
    enum Sort: String {
        case trending = "TRENDING_DESC"
        case popularity = "POPULARITY_DESC"
        case score = "SCORE_DESC"
    }

    private static let endpoint = URL(string: "https://graphql.anilist.co")!
    private static let cacheLifetime: TimeInterval = 6 * 3600

    private static let fields = """
    id title { english romaji native } coverImage { large } genres averageScore countryOfOrigin \
    chapters status siteUrl description(asHtml: false)
    """

    static func list(sort: Sort, origin: MangaOrigin, genre: MangaGenre? = nil) async throws -> [MangaItem] {
        let query = """
        query ($sort: [MediaSort], $country: CountryCode, $genres: [String], $tags: [String]) {
          Page(perPage: 20) {
            media(type: MANGA, isAdult: false, format_in: [MANGA, ONE_SHOT], sort: $sort,
                  countryOfOrigin: $country, genre_in: $genres, tag_in: $tags) { \(fields) }
          }
        }
        """
        var variables: [String: Any] = ["sort": [sort.rawValue]]
        if let country = origin.countryCode { variables["country"] = country }
        if let genre { variables[genre.isTag ? "tags" : "genres"] = [genre.name] }
        let key = "list|\(sort.rawValue)|\(origin.rawValue)|\(genre?.name ?? "")"
        return try await cached(key) {
            let data = try await post(query, variables: variables)
            return try parsePage(data)
        }
    }

    /// Truyện được cộng đồng gợi ý cho người đã đọc `title` (tên lấy từ tiêu đề trang đang đọc).
    static func recommendations(for title: String) async throws -> (source: MangaItem, items: [MangaItem])? {
        let query = """
        query ($search: String) {
          Media(search: $search, type: MANGA, isAdult: false) {
            \(fields)
            recommendations(sort: [RATING_DESC], perPage: 15) { nodes { mediaRecommendation { \(fields) } } }
          }
        }
        """
        let key = "rec|\(title.lowercased())"
        let items: [MangaItem] = try await cached(key) {
            let data = try await post(query, variables: ["search": title])
            return try parseRecommendations(data)
        }
        guard let source = items.first, items.count > 1 else { return nil }
        return (source, Array(items.dropFirst()))
    }

    // MARK: - Gọi API & phân tích

    private static func post(_ query: String, variables: [String: Any]) async throws -> Data {
        try await HTTP.postJSON(endpoint, body: ["query": query, "variables": variables],
                                headers: ["Accept": "application/json"], timeout: 15)
    }

    private struct RawMedia: Decodable {
        struct Title: Decodable { let english: String?; let romaji: String?; let native: String? }
        struct Cover: Decodable { let large: String? }
        struct Recommendations: Decodable {
            struct Node: Decodable { let mediaRecommendation: RawMedia? }
            let nodes: [Node]
        }
        let id: Int
        let title: Title
        let coverImage: Cover?
        let genres: [String]?
        let averageScore: Int?
        let countryOfOrigin: String?
        let chapters: Int?
        let status: String?
        let siteUrl: String?
        let description: String?
        let recommendations: Recommendations?

        var item: MangaItem {
            MangaItem(
                id: id,
                title: title.english ?? title.romaji ?? title.native ?? "?",
                nativeTitle: title.native,
                cover: coverImage?.large.flatMap(URL.init(string:)),
                genres: genres ?? [],
                score: averageScore,
                country: countryOfOrigin,
                chapters: chapters,
                status: status,
                summary: description.map(AniList.plainText),
                siteURL: siteUrl.flatMap(URL.init(string:))
            )
        }
    }

    static func parsePage(_ data: Data) throws -> [MangaItem] {
        struct Response: Decodable {
            struct Body: Decodable {
                struct PageBody: Decodable { let media: [RawMedia] }
                let page: PageBody
                enum CodingKeys: String, CodingKey { case page = "Page" }
            }
            let data: Body
        }
        return try JSONDecoder().decode(Response.self, from: data).data.page.media.map(\.item)
    }

    /// Phần tử đầu là truyện gốc, sau đó là các truyện được gợi ý.
    static func parseRecommendations(_ data: Data) throws -> [MangaItem] {
        struct Response: Decodable {
            struct Body: Decodable {
                let media: RawMedia?
                enum CodingKeys: String, CodingKey { case media = "Media" }
            }
            let data: Body
        }
        guard let media = try JSONDecoder().decode(Response.self, from: data).data.media else { return [] }
        let recommended = (media.recommendations?.nodes ?? []).compactMap(\.mediaRecommendation?.item)
        return [media.item] + recommended
    }

    /// Mô tả của AniList có thẻ HTML (<br>, <i>...) → văn bản thường.
    static func plainText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<br>", with: "\n", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, value) in ["&amp;": "&", "&quot;": "\"", "&#039;": "'", "&lt;": "<", "&gt;": ">", "&mdash;": "—"] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        return text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Lưu đệm

    private struct CacheEntry: Codable {
        let date: Date
        let items: [MangaItem]
    }

    @MainActor private static var memory: [String: CacheEntry] = [:]

    private static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("AniList", isDirectory: true)
    }

    private static func fileURL(_ key: String) -> URL {
        let name = key.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        return cacheDirectory.appendingPathComponent(String(name.prefix(120)) + ".json")
    }

    /// Còn hạn thì dùng bản lưu; hết hạn thì tải mới, tải lỗi (mất mạng) thì dùng tạm bản cũ.
    @MainActor
    private static func cached(_ key: String, load: () async throws -> [MangaItem]) async throws -> [MangaItem] {
        let stored = memory[key] ?? (try? Data(contentsOf: fileURL(key))).flatMap { try? JSONDecoder().decode(CacheEntry.self, from: $0) }
        if let stored, Date().timeIntervalSince(stored.date) < cacheLifetime {
            memory[key] = stored
            return stored.items
        }
        do {
            let items = try await load()
            let entry = CacheEntry(date: Date(), items: items)
            memory[key] = entry
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try? JSONEncoder().encode(entry).write(to: fileURL(key), options: .atomic)
            return items
        } catch {
            if let stored { return stored.items }
            throw error
        }
    }
}
