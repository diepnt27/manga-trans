import Foundation

/// Vùng dữ liệu dùng chung giữa app chính và Broadcast Extension.
enum AppGroup {
    /// Tên App Group trong Info.plist (key `AppGroupID`).
    static let configuredIdentifier: String =
        Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String ?? "group.com.diepnt.mangatrans"

    /// App Group thực sự được cấp. Công cụ sideload (Sideloadly, AltStore...) thường đổi tên group khi ký lại,
    /// nên ưu tiên đọc từ provisioning profile nhúng trong app, rồi mới tới tên cấu hình sẵn.
    static let identifier: String = resolveIdentifier()

    private static func resolveIdentifier() -> String {
        var candidates: [String] = []
        if let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
           let data = try? Data(contentsOf: url) {
            candidates += appGroups(fromProvisioningProfile: data)
        }
        // AltStore ghi group đã đổi tên vào key này.
        candidates += Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] ?? []
        return pickIdentifier(from: candidates, configured: configuredIdentifier) { id in
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) != nil
        }
    }

    /// Chọn group: đúng tên cấu hình → tên có chứa tên cấu hình → group đầu tiên dùng được → tên cấu hình.
    static func pickIdentifier(from candidates: [String], configured: String, isUsable: (String) -> Bool) -> String {
        let usable = candidates.filter { !$0.contains("*") && isUsable($0) }
        if usable.contains(configured) { return configured }
        let base = configured.replacingOccurrences(of: "group.", with: "")
        if let match = usable.first(where: { $0.contains(base) }) { return match }
        return usable.first ?? configured
    }

    /// Đọc danh sách App Group từ file `embedded.mobileprovision` (plist nằm trong khối CMS).
    static func appGroups(fromProvisioningProfile data: Data) -> [String] {
        guard
            let start = data.range(of: Data("<?xml".utf8)),
            let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
            let plist = try? PropertyListSerialization.propertyList(
                from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil
            ) as? [String: Any],
            let entitlements = plist["Entitlements"] as? [String: Any]
        else { return [] }
        return entitlements["com.apple.security.application-groups"] as? [String] ?? []
    }

    /// `false` nếu app chưa được cấp quyền App Group (ký sai entitlements) —
    /// khi đó app và extension không nói chuyện được với nhau.
    static var isAvailable: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) != nil
    }

    static var containerURL: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
            ?? FileManager.default.temporaryDirectory
    }

    /// Kết quả OCR mới nhất do extension ghi ra.
    static var ocrFileURL: URL { containerURL.appendingPathComponent("ocr-frame.json") }

    static let defaults: UserDefaults = UserDefaults(suiteName: identifier) ?? .standard
}

/// Tên các Darwin notification (thông báo liên tiến trình) giữa app và extension.
enum DarwinName {
    static let ocrUpdated = "com.diepnt.mangatrans.ocr-updated"
    static let broadcastStarted = "com.diepnt.mangatrans.broadcast-started"
    static let broadcastFinished = "com.diepnt.mangatrans.broadcast-finished"
    static let stopRequest = "com.diepnt.mangatrans.stop-request"
}
