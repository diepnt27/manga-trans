import SwiftUI
import WebKit

enum BrowserDisplayMode: String, CaseIterable, Identifiable {
    /// Khung dịch nổi phía trên trang.
    case panel
    /// Bản dịch đè thẳng lên bóng thoại.
    case overlay

    var id: String { rawValue }
}

struct BrowserView: View {
    @ObservedObject var model: BrowserModel
    @AppStorage("browserDisplayMode") private var displayMode: BrowserDisplayMode = .panel
    @State private var address = ""
    @State private var showBookmarks = false
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            addressBar
            ZStack(alignment: .top) {
                WebViewHost(webView: model.webView)
                if model.isTranslationEnabled {
                    switch displayMode {
                    case .panel:
                        TranslationPanel(model: model)
                    case .overlay:
                        OverlayLayer(model: model)
                    }
                }
            }
            toolbar
        }
        .background(Color.black)
        .onAppear { model.restoreIfNeeded() }
        .onChange(of: model.currentURL) { url in
            if !addressFocused { address = url }
        }
        .sheet(isPresented: $showBookmarks) {
            BookmarksSheet(model: model) { url in
                model.load(url)
                showBookmarks = false
            }
        }
    }

    private var addressBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Nhập địa chỉ web hoặc tìm kiếm", text: $address)
                    .keyboardType(.webSearch)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($addressFocused)
                    .onSubmit { model.load(address) }
                if addressFocused && !address.isEmpty {
                    Button { address = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color(white: 0.15), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            ProgressView(value: model.isLoading ? model.progress : 0)
                .progressViewStyle(.linear)
                .opacity(model.isLoading ? 1 : 0)
                .frame(height: 2)
        }
    }

    private var toolbar: some View {
        HStack {
            toolbarButton("chevron.backward", enabled: model.canGoBack) { model.goBack() }
            toolbarButton("chevron.forward", enabled: model.canGoForward) { model.goForward() }
            toolbarButton(model.isLoading ? "xmark" : "arrow.clockwise") { model.reload() }
            toolbarButton(model.isBookmarked ? "star.fill" : "star") { model.toggleBookmark() }
            toolbarButton("book") { showBookmarks = true }
            toolbarButton(displayMode == .panel ? "rectangle.topthird.inset.filled" : "text.bubble.fill") {
                displayMode = displayMode == .panel ? .overlay : .panel
            }
            .disabled(!model.isTranslationEnabled)
            toolbarButton(model.isTranslationEnabled ? "character.bubble.fill" : "character.bubble",
                          tint: model.isTranslationEnabled ? .blue : .secondary) {
                model.isTranslationEnabled.toggle()
            }
        }
        .padding(.vertical, 6)
        .background(Color(white: 0.08))
    }

    private func toolbarButton(_ icon: String, enabled: Bool = true, tint: Color = .primary,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(enabled ? tint : Color.secondary.opacity(0.4))
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .disabled(!enabled)
    }
}

struct WebViewHost: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// Khung dịch nổi: kéo được, thu gọn được.
private struct TranslationPanel: View {
    @ObservedObject var model: BrowserModel
    @AppStorage(SettingsKey.showOriginal, store: AppGroup.defaults) private var showOriginal = true
    @State private var offset: CGFloat = 0
    @State private var dragStart: CGFloat?
    @State private var collapsed = false

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                header
                    .contentShape(Rectangle())
                    .gesture(dragGesture(height: geo.size.height))
                if !collapsed {
                    content.frame(maxHeight: geo.size.height * 0.32)
                }
            }
            .background(Color(red: 0.11, green: 0.11, blue: 0.12).opacity(0.97), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.08)))
            .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
            .padding(.horizontal, 10)
            .offset(y: clamped(offset, in: geo.size.height))
        }
        .padding(.top, 8)
    }

    /// Kéo phần đầu khung để di chuyển (phần nội dung vẫn cuộn bình thường).
    private func dragGesture(height: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStart == nil { dragStart = offset }
                offset = (dragStart ?? 0) + value.translation.height
            }
            .onEnded { _ in
                offset = clamped(offset, in: height)
                dragStart = nil
            }
    }

    private func clamped(_ value: CGFloat, in height: CGFloat) -> CGFloat {
        min(max(0, value), max(0, height - 120))
    }

    private var header: some View {
        HStack {
            Capsule().fill(Color.white.opacity(0.25)).frame(width: 36, height: 5)
            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button { model.rescan() } label: { Image(systemName: "arrow.triangle.2.circlepath") }
            Button { withAnimation { collapsed.toggle() } } label: {
                Image(systemName: collapsed ? "chevron.down" : "chevron.up")
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 14) {
                if model.entries.isEmpty {
                    Text("Mở trang truyện rồi dừng cuộn — bản dịch sẽ hiện ở đây.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(model.entries.enumerated()), id: \.offset) { _, entry in
                        VStack(spacing: 6) {
                            if showOriginal {
                                Text(entry.original)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color(white: 0.72))
                                Rectangle().fill(Color.white.opacity(0.18)).frame(height: 1).padding(.horizontal, 30)
                            }
                            Text(entry.translation)
                                .font(.body.weight(.medium))
                                .foregroundStyle(color(for: entry.state))
                        }
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
    }

    private func color(for state: PiPEntry.State) -> Color {
        switch state {
        case .done: return Color(red: 0.50, green: 0.82, blue: 0.78)
        case .pending: return .secondary
        case .error: return Color(red: 1, green: 0.45, blue: 0.42)
        }
    }
}

/// Bản dịch đè lên đúng vị trí bóng thoại. Ẩn khi đang cuộn, không chặn thao tác chạm.
private struct OverlayLayer: View {
    @ObservedObject var model: BrowserModel

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(model.overlays) { overlay in
                    let frame = frameFor(overlay, in: geo.size)
                    Text(overlay.text)
                        .font(.system(size: fontSize(overlay, in: geo.size), weight: .bold))
                        .foregroundStyle(overlay.state == .error ? Color.red : Color.black)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.35)
                        .padding(4)
                        .frame(width: frame.width, height: frame.height)
                        .background(Color.white.opacity(0.96), in: RoundedRectangle(cornerRadius: 8))
                        .position(x: frame.midX, y: frame.midY)
                }
            }
            .opacity(model.isScrolling ? 0 : 1)
            .animation(.easeOut(duration: 0.15), value: model.overlays)
        }
        .allowsHitTesting(false)
    }

    private func frameFor(_ overlay: BrowserModel.Overlay, in size: CGSize) -> CGRect {
        let rect = CGRect(x: overlay.rect.minX * size.width, y: overlay.rect.minY * size.height,
                          width: overlay.rect.width * size.width, height: overlay.rect.height * size.height)
        // Nới rộng một chút: tiếng Việt thường dài hơn tiếng Anh.
        let grown = rect.insetBy(dx: -max(8, rect.width * 0.08), dy: -max(6, rect.height * 0.12))
        return grown.intersection(CGRect(origin: .zero, size: size))
    }

    private func fontSize(_ overlay: BrowserModel.Overlay, in size: CGSize) -> CGFloat {
        min(26, max(11, overlay.lineHeight * size.height * 0.8))
    }
}

private struct BookmarksSheet: View {
    @ObservedObject var model: BrowserModel
    let open: (String) -> Void

    var body: some View {
        NavigationStack {
            List {
                if model.bookmarks.isEmpty {
                    Text("Chưa có dấu trang. Nhấn ☆ khi đang xem trang để lưu.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.bookmarks) { bookmark in
                    Button { open(bookmark.url) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(bookmark.title).lineLimit(1)
                            Text(bookmark.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .onDelete { model.removeBookmarks(at: $0) }
            }
            .navigationTitle("Dấu trang")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}
