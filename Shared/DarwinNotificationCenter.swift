import Foundation

/// Bọc CFNotificationCenter Darwin để gửi/nhận thông báo giữa app và extension.
/// Darwin notification không mang dữ liệu — dữ liệu đi qua file/UserDefaults của App Group.
final class DarwinNotificationCenter {
    static let shared = DarwinNotificationCenter()

    private var handlers: [String: [() -> Void]] = [:]
    private let lock = NSLock()

    private init() {}

    func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil, nil, true
        )
    }

    func observe(_ name: String, handler: @escaping () -> Void) {
        lock.lock()
        let isFirstObserver = handlers[name] == nil
        handlers[name, default: []].append(handler)
        lock.unlock()
        guard isFirstObserver else { return }

        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observer,
            { _, observer, name, _, _ in
                guard let observer, let name else { return }
                let center = Unmanaged<DarwinNotificationCenter>.fromOpaque(observer).takeUnretainedValue()
                center.dispatch(name.rawValue as String)
            },
            name as CFString,
            nil,
            .deliverImmediately
        )
    }

    private func dispatch(_ name: String) {
        lock.lock()
        let current = handlers[name] ?? []
        lock.unlock()
        current.forEach { $0() }
    }
}
