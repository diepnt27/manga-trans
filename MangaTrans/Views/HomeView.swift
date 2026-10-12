import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var coordinator: TranslationCoordinator
    @ObservedObject var pip: PiPManager

    @AppStorage(SettingsKey.engine, store: AppGroup.defaults) private var engine: TranslatorEngine = .google
    @AppStorage(SettingsKey.windowSize, store: AppGroup.defaults) private var windowSize: WindowSize = .normal
    @AppStorage(SettingsKey.showOriginal, store: AppGroup.defaults) private var showOriginal = true
    @AppStorage(SettingsKey.autoSwitchedToFast, store: AppGroup.defaults) private var autoSwitchedToFast = false

    private let accent = LinearGradient(colors: [Color(red: 0.25, green: 0.55, blue: 0.98), Color(red: 0.45, green: 0.45, blue: 0.95)],
                                        startPoint: .leading, endPoint: .trailing)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    languageBar
                    preview
                    optionRows
                    statusView
                    startButton
                    warnings
                    guide
                    // Nút hệ thống "Bắt đầu phát sóng" — ẩn, được bấm bằng code.
                    BroadcastPickerHost()
                        .frame(width: 1, height: 1)
                        .opacity(0.02)
                }
                .padding(16)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Manga Mode")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var languageBar: some View {
        HStack(spacing: 12) {
            chip("🇺🇸 English")
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            chip("🇻🇳 Tiếng Việt")
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color(white: 0.15), in: RoundedRectangle(cornerRadius: 12))
    }

    private var preview: some View {
        let size = windowSize.canvasSize
        return PiPPreview(manager: pip)
            .aspectRatio(size.width / size.height, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [8, 6]))
                    .foregroundStyle(Color.gray.opacity(0.6))
            }
            .overlay {
                if pip.isActive {
                    Text("Cửa sổ nổi đang bật")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black, in: RoundedRectangle(cornerRadius: 16))
                }
            }
    }

    private var optionRows: some View {
        VStack(spacing: 0) {
            row(icon: "character.book.closed", title: "Bộ dịch") {
                Picker("Bộ dịch", selection: $engine) {
                    ForEach(TranslatorEngine.allCases) { Text($0.title).tag($0) }
                }
            }
            Divider().padding(.leading, 56)
            row(icon: "rectangle.on.rectangle", title: "Cỡ cửa sổ") {
                Picker("Cỡ cửa sổ", selection: $windowSize) {
                    ForEach(WindowSize.allCases) { Text($0.title).tag($0) }
                }
            }
            Divider().padding(.leading, 56)
            row(icon: "text.quote", title: "Hiện câu gốc") {
                Toggle("", isOn: $showOriginal).labelsHidden()
            }
        }
        .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 16))
    }

    private func row<Accessory: View>(icon: String, title: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .foregroundStyle(Color.blue)
                .frame(width: 30, height: 30)
                .background(Color.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            Text(title)
            Spacer()
            accessory()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var statusView: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(coordinator.isBroadcasting ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Spacer()
        }
    }

    private var statusText: String {
        guard coordinator.isBroadcasting else { return "Chưa chạy" }
        switch coordinator.phase {
        case .idle, .waiting: return "Đang quét màn hình — mở truyện để đọc"
        case .translating: return "Đang dịch…"
        case .showing: return "Đã dịch \(coordinator.entries.count) bóng thoại"
        case .error(let message): return "Lỗi: \(message)"
        }
    }

    private var startButton: some View {
        Button {
            if coordinator.isBroadcasting {
                coordinator.stop()
            } else {
                coordinator.start()
            }
        } label: {
            Label(coordinator.isBroadcasting ? "Dừng" : "Bắt đầu",
                  systemImage: coordinator.isBroadcasting ? "stop.fill" : "rectangle.on.rectangle")
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .foregroundStyle(.white)
                .background(coordinator.isBroadcasting ? AnyShapeStyle(Color.red.opacity(0.85)) : AnyShapeStyle(accent),
                            in: RoundedRectangle(cornerRadius: 16))
        }
    }

    @ViewBuilder
    private var warnings: some View {
        if !AppGroup.isAvailable {
            warning("App chưa được cấp quyền App Group (\(AppGroup.identifier)). Extension sẽ không gửi được chữ về app — kiểm tra lại cách ký app.")
        }
        if !pip.isSupported {
            warning("Thiết bị không hỗ trợ Picture-in-Picture.")
        }
        if autoSwitchedToFast {
            HStack(alignment: .top) {
                warning("Lần trước phần quét màn hình bị iOS tắt vì thiếu RAM, đã tự chuyển sang OCR \"Nhanh\".")
                Button("OK") { autoSwitchedToFast = false }
            }
        }
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var guide: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Cách dùng").font(.headline)
            Text("1. Nhấn **Bắt đầu** → cửa sổ nổi hiện lên → chọn **Bắt đầu phát sóng**.")
            Text("2. Mở Safari / app đọc truyện. Dừng cuộn một chút, bản dịch sẽ hiện trong cửa sổ nổi.")
            Text("3. Kéo cửa sổ nổi lên sát mép trên hoặc dưới để không che bóng thoại.")
            Text("4. Dừng: nhấn X trên cửa sổ nổi, hoặc chạm thanh đỏ trên đồng hồ.")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 16))
    }
}
