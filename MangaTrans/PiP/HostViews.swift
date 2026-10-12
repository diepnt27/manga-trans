import SwiftUI
import AVFoundation
import ReplayKit

/// Vùng xem trước trong app — chứa layer nguồn của cửa sổ nổi (PiP chỉ bật được khi layer này đang trên màn hình).
struct PiPPreview: UIViewRepresentable {
    let manager: PiPManager

    func makeUIView(context: Context) -> SampleBufferHostView {
        SampleBufferHostView(displayLayer: manager.displayLayer)
    }

    func updateUIView(_ uiView: SampleBufferHostView, context: Context) {}
}

final class SampleBufferHostView: UIView {
    private let displayLayer: AVSampleBufferDisplayLayer

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        super.init(frame: .zero)
        backgroundColor = .black
        layer.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }
}

/// Mở hộp thoại hệ thống "Bắt đầu phát sóng" cho Broadcast Extension của app.
final class BroadcastLauncher {
    static let shared = BroadcastLauncher()

    let picker: RPSystemBroadcastPickerView = {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        picker.preferredExtension = (Bundle.main.bundleIdentifier ?? "") + ".BroadcastExt"
        picker.showsMicrophoneButton = false
        return picker
    }()

    func present() {
        // RPSystemBroadcastPickerView không có API mở bằng code → giả lập bấm nút bên trong.
        func findButton(in view: UIView) -> UIButton? {
            if let button = view as? UIButton { return button }
            for sub in view.subviews {
                if let button = findButton(in: sub) { return button }
            }
            return nil
        }
        findButton(in: picker)?.sendActions(for: .touchUpInside)
    }
}

struct BroadcastPickerHost: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        BroadcastLauncher.shared.picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}
