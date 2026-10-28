import SwiftUI

/// Các hàng truyện gợi ý của trang Tab mới; dùng chung cho mọi tab (mở tab mới là có ngay).
@MainActor
final class DiscoverFeed: ObservableObject {
    static let shared = DiscoverFeed()

    struct Row: Identifiable {
        let id: String
        let title: String
        var items: [MangaItem] = []
        var isLoading = true
    }

    @Published private(set) var rows: [Row] = []
    private var task: Task<Void, Never>?
    private var signature = ""
    private var loadedAt = Date.distantPast

    /// Tải lại khi đổi loại truyện / thể loại / truyện vừa đọc, hoặc sau 30 phút.
    func refresh(store: DiscoverStore, force: Bool = false) {
        let titles = store.recentTitles(limit: 2)
        let genres = store.favoriteGenres.prefix(3).compactMap { name in MangaGenre.all.first { $0.name == name } }
        let origin = store.origin
        let newSignature = ([origin.rawValue] + genres.map(\.name) + titles).joined(separator: "|")
        guard force || newSignature != signature || Date().timeIntervalSince(loadedAt) > 1800 else { return }
        signature = newSignature
        loadedAt = Date()

        typealias Loader = @Sendable () async throws -> [MangaItem]
        var plan: [(Row, Loader)] = []
        for title in titles {
            plan.append((Row(id: "rec|\(title)", title: "Vì bạn đọc \(title)"), {
                guard let result = try await AniList.recommendations(for: title) else { return [] }
                return result.items.filter { origin == .all || Self.matches($0, origin) }
            }))
        }
        for genre in genres {
            plan.append((Row(id: "genre|\(genre.name)", title: "Gợi ý: \(genre.title)"), {
                try await AniList.list(sort: .trending, origin: origin, genre: genre)
            }))
        }
        plan.append((Row(id: "trending", title: "Đang hot"), { try await AniList.list(sort: .trending, origin: origin) }))
        plan.append((Row(id: "popular", title: "Phổ biến nhất"), { try await AniList.list(sort: .popularity, origin: origin) }))
        plan.append((Row(id: "score", title: "Điểm cao nhất"), { try await AniList.list(sort: .score, origin: origin) }))

        // Giữ truyện đang hiện của hàng cũ trong lúc tải để màn hình không nhấp nháy.
        let previous = Dictionary(rows.map { ($0.id, $0.items) }, uniquingKeysWith: { first, _ in first })
        rows = plan.map { row, _ in
            var row = row
            row.items = previous[row.id] ?? []
            return row
        }
        task?.cancel()
        task = Task { [weak self] in
            await withTaskGroup(of: (String, [MangaItem]?).self) { group in
                for (row, load) in plan {
                    group.addTask { (row.id, try? await load()) }
                }
                for await (id, items) in group {
                    guard let self, !Task.isCancelled, let index = self.rows.firstIndex(where: { $0.id == id }) else { continue }
                    if let items { self.rows[index].items = items }
                    self.rows[index].isLoading = false
                }
            }
        }
    }

    private nonisolated static func matches(_ item: MangaItem, _ origin: MangaOrigin) -> Bool {
        switch origin {
        case .all: return true
        case .manga: return item.country == "JP"
        case .manhwa: return item.country == "KR"
        case .manhua: return item.country == "CN" || item.country == "TW"
        }
    }
}

/// Trang Tab mới: đọc tiếp, trang đọc truyện, truyện gợi ý theo sở thích và bảng xếp hạng.
struct StartPageView: View {
    let open: (String) -> Void

    @ObservedObject private var store = DiscoverStore.shared
    @ObservedObject private var feed = DiscoverFeed.shared
    @State private var selected: MangaItem?
    @State private var showGenres = false
    @State private var showAddSite = false
    @State private var newSite = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Hôm nay đọc gì?")
                    .font(.largeTitle.bold())
                    .padding(.horizontal)
                    .padding(.top, 8)

                if !store.continueReading.isEmpty { continueSection }
                sitesSection
                preferencesSection
                ForEach(feed.rows) { row in
                    if row.isLoading || !row.items.isEmpty { mangaRow(row) }
                }
                Text("Danh sách truyện và xếp hạng từ AniList.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
            .padding(.bottom, 90) // chừa chỗ cho thanh công cụ
        }
        .background(Color.black)
        .scrollDismissesKeyboard(.immediately)
        .onAppear { feed.refresh(store: store) }
        .onChange(of: store.origin) { _ in feed.refresh(store: store) }
        .onChange(of: store.favoriteGenres) { _ in feed.refresh(store: store) }
        .refreshable { feed.refresh(store: store, force: true) }
        .sheet(item: $selected) { item in
            MangaDetailSheet(item: item, sites: store.sites) { url in
                selected = nil
                open(url)
            }
        }
        .sheet(isPresented: $showGenres) { GenrePicker(store: store) }
        .alert("Thêm trang đọc truyện", isPresented: $showAddSite) {
            TextField("vd: mangadex.org", text: $newSite)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("Thêm") {
                store.addSite(newSite)
                newSite = ""
            }
            Button("Huỷ", role: .cancel) { newSite = "" }
        }
    }

    // MARK: - Đọc tiếp

    private var continueSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Đọc tiếp")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(store.continueReading) { entry in
                        Button { open(entry.url) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.mangaTitle)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                                Text(chapterLabel(entry))
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .lineLimit(1)
                                Text(entry.host)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(width: 150, height: 92, alignment: .leading)
                            .padding(12)
                            .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) { store.removeHistory(entry) } label: {
                                Label("Xoá khỏi lịch sử", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    /// "Chapter 31" lấy từ tiêu đề trang.
    private func chapterLabel(_ entry: ReadingEntry) -> String {
        let pattern = "(?i)(chapter|chap|chương|episode|ep\\.?)\\s*#?[0-9.]+"
        guard let range = entry.pageTitle.range(of: pattern, options: .regularExpression) else { return "Đọc tiếp" }
        return String(entry.pageTitle[range]).capitalized
    }

    // MARK: - Trang đọc truyện

    private var sitesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Trang đọc truyện")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 14) {
                ForEach(store.sites) { site in
                    Button { open(site.url) } label: { SiteTile(name: site.name, host: site.host) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) { store.hideSite(site) } label: {
                                Label("Ẩn trang này", systemImage: "eye.slash")
                            }
                            Button { store.restoreDefaultSites() } label: {
                                Label("Khôi phục danh sách mặc định", systemImage: "arrow.counterclockwise")
                            }
                        }
                }
                Button { showAddSite = true } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 20, weight: .semibold))
                            .frame(width: 52, height: 52)
                            .background(Color(white: 0.15), in: RoundedRectangle(cornerRadius: 14))
                        Text("Thêm").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
        }
    }

    // MARK: - Sở thích

    private var preferencesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Loại truyện", selection: $store.origin) {
                ForEach(MangaOrigin.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button { showGenres = true } label: {
                        Label(store.favoriteGenres.isEmpty ? "Chọn thể loại bạn thích" : "Thể loại",
                              systemImage: "slider.horizontal.3")
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color.accentColor.opacity(0.2), in: Capsule())
                    }
                    ForEach(store.favoriteGenres, id: \.self) { name in
                        Text(MangaGenre.title(for: name))
                            .font(.footnote)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color(white: 0.15), in: Capsule())
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    // MARK: - Hàng truyện

    private func mangaRow(_ row: DiscoverFeed.Row) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(row.title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    if row.items.isEmpty {
                        ForEach(0..<4, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color(white: 0.12))
                                .frame(width: 112, height: 160)
                        }
                    }
                    ForEach(row.items) { item in
                        Button { selected = item } label: { MangaCard(item: item) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.title3.bold())
            .lineLimit(1)
            .padding(.horizontal)
    }
}

private struct SiteTile: View {
    let name: String
    let host: String

    var body: some View {
        VStack(spacing: 6) {
            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(color, in: RoundedRectangle(cornerRadius: 14))
            Text(name)
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
    }

    /// Mỗi trang một màu cố định theo tên miền.
    private var color: Color {
        let palette: [Color] = [.red, .orange, .pink, .purple, .indigo, .blue, .teal, .green]
        let hash = host.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[hash % palette.count].opacity(0.85)
    }
}

private struct MangaCard: View {
    let item: MangaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Cover(url: item.cover)
                .frame(width: 112, height: 160)
                .overlay(alignment: .topLeading) {
                    if let score = item.score {
                        Label("\(score)", systemImage: "star.fill")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.7), in: Capsule())
                            .foregroundStyle(.yellow)
                            .padding(5)
                    }
                }
            Text(item.title)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(item.originLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: 112)
    }
}

private struct Cover: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeIn(duration: 0.2))) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Color(white: 0.14).overlay(
                    Image(systemName: "book.closed").foregroundStyle(.secondary)
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// Chi tiết truyện: thông tin, mô tả, và chỗ tìm đọc.
private struct MangaDetailSheet: View {
    let item: MangaItem
    let sites: [ReadingSite]
    let open: (String) -> Void
    @State private var expanded = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 14) {
                        Cover(url: item.cover).frame(width: 120, height: 172)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.title).font(.title3.bold())
                            if let native = item.nativeTitle, native != item.title {
                                Text(native).font(.footnote).foregroundStyle(.secondary)
                            }
                            Text([item.originLabel, item.statusLabel, item.chapters.map { "\($0) chương" }]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            if let score = item.score {
                                Label("\(score)/100", systemImage: "star.fill")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.yellow)
                            }
                        }
                    }
                    if !item.genres.isEmpty {
                        Text(item.genres.map(MangaGenre.title(for:)).joined(separator: " · "))
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    if let summary = item.summary, !summary.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(summary)
                                .font(.subheadline)
                                .lineLimit(expanded ? nil : 5)
                            Button(expanded ? "Thu gọn" : "Xem thêm") { expanded.toggle() }
                                .font(.footnote.weight(.semibold))
                        }
                    }

                    Text("Tìm đọc").font(.headline).padding(.top, 4)
                    VStack(spacing: 8) {
                        readButton("Tìm trên Google", icon: "magnifyingglass",
                                   url: DiscoverStore.googleSearch("\(item.title) manga read online"))
                        ForEach(sites) { site in
                            readButton("Tìm trên \(site.name)", icon: "book", url: site.searchURL(for: item.title))
                        }
                        if let siteURL = item.siteURL {
                            readButton("Xem trên AniList", icon: "info.circle", url: siteURL.absoluteString)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Chi tiết")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Đóng") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func readButton(_ title: String, icon: String, url: String) -> some View {
        Button { open(url) } label: {
            HStack {
                Image(systemName: icon).frame(width: 22)
                Text(title).lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

/// Chọn thể loại yêu thích — mỗi thể loại thành một hàng gợi ý (tối đa 3 hàng).
private struct GenrePicker: View {
    @ObservedObject var store: DiscoverStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
                    ForEach(MangaGenre.all) { genre in
                        let on = store.favoriteGenres.contains(genre.name)
                        Button { store.toggleGenre(genre.name) } label: {
                            Text(genre.title)
                                .font(.subheadline.weight(on ? .semibold : .regular))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(on ? Color.accentColor : Color(white: 0.15), in: Capsule())
                                .foregroundStyle(on ? Color.white : Color.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
                Text("Thể loại chọn trước hiện trước; trang Tab mới hiện gợi ý cho 3 thể loại đầu tiên.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
            .navigationTitle("Thể loại yêu thích")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Xong") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
