// Adapted from apple1day/nice@6aa1447; identifiers are private to Cassette.
import Foundation

nonisolated struct SigningReminderRequest: Equatable, Sendable {
    let identifier: String
    let fireDate: Date
    let expirationDate: Date
    let hoursBefore: Int
}

nonisolated enum SigningReminderPlan {
    static let identifiers = ["cassette.signing-expiry.48h", "cassette.signing-expiry.24h"]

    static func requests(expiration: Date?, now: Date) -> [SigningReminderRequest] {
        guard let expiration, expiration.timeIntervalSince1970.isFinite else { return [] }
        return zip([48, 24], identifiers).compactMap { hours, identifier in
            let date = expiration.addingTimeInterval(-Double(hours) * 3600)
            // Never replay missed reminders or schedule at/after expiry.
            guard date > now else { return nil }
            return SigningReminderRequest(identifier: identifier, fireDate: date,
                                          expirationDate: expiration, hoursBefore: hours)
        }
    }
}

nonisolated enum SigningNotificationPermission: Equatable, Sendable {
    case notDetermined, denied, authorized, quiet, unavailable
    var allowsDelivery: Bool { self == .authorized || self == .quiet }
}

nonisolated protocol SigningNotificationClient: Sendable {
    func permission() async -> SigningNotificationPermission
    func requestPermission() async throws
    func clear(identifiers: [String]) async
    func add(_ request: SigningReminderRequest) async throws -> Bool
}

nonisolated struct SigningReminderReport: Equatable, Sendable {
    let permission: SigningNotificationPermission
    let scheduled: [SigningReminderRequest]
    let error: String?
}

/// Serialize asynchronous mutations. Revision checks skip obsolete enable/renew
/// work after a later disable, including while the permission dialog is visible.
@MainActor
final class SigningReminderScheduler {
    private let client: any SigningNotificationClient
    private var tail: Task<SigningReminderReport, Never>?
    private var revision = 0

    init(client: any SigningNotificationClient) { self.client = client }

    func synchronize(expiration: Date?, enabled: Bool, requestPermission: Bool = false,
                     now: @escaping @Sendable () -> Date = { Date() }) -> Task<SigningReminderReport, Never> {
        revision += 1
        let currentRevision = revision
        let previous = tail
        let client = client
        let task = Task { @MainActor in
            _ = await previous?.value
            var permission = await client.permission()
            var errorMessage: String?
            if self.revision == currentRevision, enabled, expiration != nil,
               requestPermission, permission == .notDetermined {
                do { try await client.requestPermission() }
                catch { errorMessage = "无法申请通知权限，请稍后重试。" }
                permission = await client.permission()
            }
            // Only these two requests are removed. Other notifications survive.
            await client.clear(identifiers: SigningReminderPlan.identifiers)
            let requests = self.revision == currentRevision && enabled && permission.allowsDelivery
                ? SigningReminderPlan.requests(expiration: expiration, now: now()) : []
            var scheduled: [SigningReminderRequest] = []
            do {
                for request in requests {
                    guard self.revision == currentRevision, request.fireDate > now() else { continue }
                    if try await client.add(request) { scheduled.append(request) }
                }
                if self.revision != currentRevision {
                    await client.clear(identifiers: SigningReminderPlan.identifiers)
                    scheduled = []
                }
            } catch {
                await client.clear(identifiers: SigningReminderPlan.identifiers)
                scheduled = []
                errorMessage = "到期通知安排失败，App 内倒计时仍可查看，请点击重新检查。"
            }
            return SigningReminderReport(permission: permission, scheduled: scheduled, error: errorMessage)
        }
        tail = task
        return task
    }
}

#if os(iOS)
import UserNotifications

// UNUserNotificationCenter supports asynchronous access; mutations are serialized above.
nonisolated final class SystemSigningNotificationClient: SigningNotificationClient, @unchecked Sendable {
    private let center = UNUserNotificationCenter.current()

    func permission() async -> SigningNotificationPermission {
        switch (await center.notificationSettings()).authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        case .provisional, .ephemeral: return .quiet
        @unknown default: return .unavailable
        }
    }

    func requestPermission() async throws {
        _ = try await center.requestAuthorization(options: [.alert, .sound])
    }

    func clear(identifiers: [String]) async {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func add(_ request: SigningReminderRequest) async throws -> Bool {
        guard request.fireDate > Date() else { return false }
        let content = UNMutableNotificationContent()
        content.title = "小熊音乐签名即将到期"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm zzz"
        content.body = "描述文件将于 \(formatter.string(from: request.expirationDate)) 到期（约 \(request.hoursBefore) 小时后）。请通过 Xcode 刷新签名并覆盖安装，不要卸载 App，以免删除本地歌曲。"
        content.sound = .default
        content.threadIdentifier = "cassette.signing-expiry"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                                 from: request.fireDate)
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        try await center.add(UNNotificationRequest(identifier: request.identifier,
                                                 content: content, trigger: trigger))
        return true
    }
}
#endif
