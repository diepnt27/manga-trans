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
    /// Toàn màn hình: ẩn thanh địa chỉ, thanh công cụ và thanh tab để dành chỗ cho truyện.
    @State private var isFullScreen = false
    @FocusState private var addressFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !isFullScreen { addressBar }
                ZStack(alignment: .top) {
                    WebViewHost(webView: model.webView)
                    if model.isTranslationEnabled && displayMode == .overlay {
                        OverlayLayer(model: model)
                    }
                }
                if !isFullScreen { toolbar }
            }
            // Khung dịch nằm trên cả thanh địa chỉ → kéo lên sát mép trên được, không chiếm chỗ đọc truyện.
            .overlay {
                if model.isTranslationEnabled && displayMode == .panel {
                    TranslationPanel(model: model)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if isFullScreen {
                    Button { setFullScreen(false) } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.black.opacity(0.55), in: Circle())
                    }
                    .accessibilityLabel("Thoát toàn màn hình")
                    .padding(16)
                }
            }
            .background(Color.black)
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(isFullScreen ? .hidden : .visible, for: .tabBar)
        }
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
                } else {
                    Button { setFullScreen(true) } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Toàn màn hình")
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

    private func setFullScreen(_ value: Bool) {
        addressFocused = false
        withAnimation(.easeInOut(duration: 0.2)) { isFullScreen = value }
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
    // Vị trí & kích thước khung (tỉ lệ theo vùng web) — nhớ giữa các lần mở app.
    @AppStorage("panelX") private var storedX = Double(PanelLayout.defaultFrame.minX)
    @AppStorage("panelY") private var storedY = Double(PanelLayout.defaultFrame.minY)
    @AppStorage("panelW") private var storedW = Double(PanelLayout.defaultFrame.width)
    @AppStorage("panelH") private var storedH = Double(PanelLayout.defaultFrame.height)
    /// Khung đang kéo/đổi cỡ (chưa lưu).
    @State private var liveFrame: CGRect?
    @State private var gestureStart: CGRect?
    @State private var collapsed = false

    var body: some View {
        GeometryReader { geo in
            let frame = liveFrame ?? PanelLayout.frame(from: storedFrame, in: geo.size)
            VStack(spacing: 0) {
                header
                    .contentShape(Rectangle())
                    .gesture(moveGesture(container: geo.size, current: frame))
                    .onTapGesture(count: 2) { withAnimation { storedFrame = PanelLayout.defaultFrame } }
                if !collapsed {
                    content.frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .frame(width: frame.width, height: collapsed ? nil : frame.height, alignment: .top)
            .background(Color(red: 0.11, green: 0.11, blue: 0.12).opacity(0.97), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.08)))
            .overlay(alignment: .bottomTrailing) {
                if !collapsed {
                    resizeHandle.gesture(resizeGesture(container: geo.size, current: frame))
                }
            }
            .simultaneousGesture(pinchGesture(container: geo.size, current: frame))
            // Đổ bóng tốn công vẽ lại → tắt khi đang kéo cho mượt.
            .shadow(color: .black.opacity(liveFrame == nil ? 0.5 : 0), radius: liveFrame == nil ? 10 : 0, y: 4)
            .offset(x: frame.minX, y: frame.minY)
        }
    }

    private var storedFrame: CGRect {
        get { CGRect(x: storedX, y: storedY, width: storedW, height: storedH) }
        nonmutating set {
            storedX = Double(newValue.minX)
            storedY = Double(newValue.minY)
            storedW = Double(newValue.width)
            storedH = Double(newValue.height)
        }
    }

    private func commit(_ frame: CGRect?, in container: CGSize) {
        if let frame { storedFrame = PanelLayout.fraction(of: frame, in: container) }
        liveFrame = nil
        gestureStart = nil
    }

    /// Kéo phần đầu khung để di chuyển tự do (phần nội dung vẫn cuộn bình thường). Chạm 2 lần: về chỗ cũ.
    private func moveGesture(container: CGSize, current: CGRect) -> some Gesture {
        // Đo theo toạ độ màn hình: đo theo khung (đang di chuyển) làm khung bị giật.
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                let start = gestureStart ?? current
                gestureStart = start
                liveFrame = PanelLayout.clamp(start.offsetBy(dx: value.translation.width, dy: value.translation.height),
                                              in: container)
            }
            .onEnded { _ in commit(liveFrame, in: container) }
    }

    /// Kéo góc dưới bên phải để đổi kích thước.
    private func resizeGesture(container: CGSize, current: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                let start = gestureStart ?? current
                gestureStart = start
                let resized = CGRect(x: start.minX, y: start.minY,
                                     width: start.width + value.translation.width,
                                     height: start.height + value.translation.height)
                liveFrame = PanelLayout.clamp(resized, in: container)
            }
            .onEnded { _ in commit(liveFrame, in: container) }
    }

    /// Chụm/mở 2 ngón trên khung để thu nhỏ/phóng to (giữ nguyên tâm).
    private func pinchGesture(container: CGSize, current: CGRect) -> some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                let start = gestureStart ?? current
                gestureStart = start
                let width = start.width * scale, height = start.height * scale
                let scaled = CGRect(x: start.midX - width / 2, y: start.midY - height / 2, width: width, height: height)
                liveFrame = PanelLayout.clamp(scaled, in: container)
            }
            .onEnded { _ in commit(liveFrame, in: container) }
    }

    private var resizeHandle: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(Color.white.opacity(0.55))
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
            .accessibilityLabel("Đổi kích thước khung dịch")
    }

    private var header: some View {
        // Thanh đầu mỏng: chỗ để kéo khung, trạng thái và 2 nút nhỏ.
        HStack(spacing: 6) {
            Capsule().fill(Color.white.opacity(0.25)).frame(width: 30, height: 4)
            Text(model.status)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button { model.rescan() } label: {
                Image(systemName: "arrow.triangle.2.circlepath").frame(width: 30, height: 24)
            }
            .accessibilityLabel("Dịch lại")
            Button { withAnimation { collapsed.toggle() } } label: {
                Image(systemName: collapsed ? "chevron.down" : "chevron.up").frame(width: 30, height: 24)
            }
            .accessibilityLabel(collapsed ? "Mở rộng" : "Thu gọn")
        }
        .font(.footnote.weight(.semibold))
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 10) {
                if model.entries.isEmpty {
                    Text("Mở trang truyện rồi dừng cuộn — bản dịch sẽ hiện ở đây.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(model.entries.enumerated()), id: \.offset) { _, entry in
                        VStack(spacing: 4) {
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
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
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

/// Tính toán khung dịch: lưu theo tỉ lệ vùng web để hợp mọi cỡ màn hình.
enum PanelLayout {
    static let defaultFrame = CGRect(x: 0.02, y: 0, width: 0.96, height: 0.22)
    static let minSize = CGSize(width: 200, height: 110)

    static func frame(from fraction: CGRect, in container: CGSize) -> CGRect {
        clamp(CGRect(x: fraction.minX * container.width, y: fraction.minY * container.height,
                     width: fraction.width * container.width, height: fraction.height * container.height),
              in: container)
    }

    static func fraction(of frame: CGRect, in container: CGSize) -> CGRect {
        guard container.width > 0, container.height > 0 else { return defaultFrame }
        return CGRect(x: frame.minX / container.width, y: frame.minY / container.height,
                      width: frame.width / container.width, height: frame.height / container.height)
    }

    /// Giữ khung trong vùng web và không nhỏ hơn mức tối thiểu.
    static func clamp(_ frame: CGRect, in container: CGSize) -> CGRect {
        let width = min(max(frame.width, minSize.width), max(minSize.width, container.width))
        let height = min(max(frame.height, minSize.height), max(minSize.height, container.height))
        let x = min(max(frame.minX, 0), max(0, container.width - width))
        let y = min(max(frame.minY, 0), max(0, container.height - height))
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
