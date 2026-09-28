import SwiftUI

// Keep macOS behavior unchanged. No UIKit / notification adapter is compiled there.
extension View {
    @ViewBuilder
    func cassetteSigningLifecycle() -> some View {
        #if os(iOS)
        modifier(SigningLifecycleModifier())
        #else
        self
        #endif
    }

    @ViewBuilder
    func cassetteSigningInset(alwaysVisible: Bool = false) -> some View {
        #if os(iOS)
        safeAreaInset(edge: .top, spacing: 0) {
            SigningEntryCard(alwaysVisible: alwaysVisible)
        }
        #else
        self
        #endif
    }
}

#if os(iOS)
import UIKit
import Combine

@MainActor
private struct SigningLifecycleModifier: ViewModifier {
    @StateObject private var signing = SigningStatusModel()
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .environmentObject(signing)
            .task { signing.activate() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { signing.activate() }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                signing.activate()
            }
    }
}

private extension SigningUrgency {
    var color: Color {
        switch self {
        case .normal: return .green
        case .warning: return .orange
        case .urgent, .expired: return .red
        }
    }
    var icon: String {
        switch self {
        case .normal: return "checkmark.shield"
        case .warning, .urgent: return "exclamationmark.shield"
        case .expired: return "xmark.shield"
        }
    }
}

/// The clock lives only in the small card, not MainTabView or the music player.
@MainActor
private struct SigningEntryCard: View {
    @EnvironmentObject private var signing: SigningStatusModel
    let alwaysVisible: Bool
    @State private var showingDetails = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if alwaysVisible || needsWarning(now: context.date) {
                Button { showingDetails = true } label: {
                    SigningCompactContent(status: signing.status, now: context.date)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(alwaysVisible ? "signing.summary" : "signing.warning")
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .sheet(isPresented: $showingDetails) {
            SigningDetailsView().environmentObject(signing)
        }
    }

    private func needsWarning(now: Date) -> Bool {
        guard let expiration = signing.status.expirationDate else { return false }
        return SigningUrgency.resolve(expiration: expiration, now: now) != .normal
    }
}

@MainActor
private struct SigningCompactContent: View {
    let status: SigningStatus
    let now: Date

    private var accent: Color {
        guard let expiration = status.expirationDate else { return .secondary }
        return SigningUrgency.resolve(expiration: expiration, now: now).color
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.title2).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("签名有效期").font(.caption).foregroundStyle(.secondary)
                switch status {
                case .loading:
                    Text("正在读取签名信息…").font(.subheadline)
                case .unavailable:
                    Text("无法确定到期时间").font(.subheadline.bold())
                    Text("点击查看详情与提醒设置").font(.caption).foregroundStyle(.secondary)
                case let .available(profile):
                    Text(profile.expirationDate <= now ? "描述文件已到期" : "剩余 \(SigningCountdown.text(expiration: profile.expirationDate, now: now))")
                        .font(.headline).monospacedDigit().foregroundStyle(accent)
                    Text("到期：\(profile.expirationDate.formatted(date: .numeric, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(accent.opacity(0.25), lineWidth: 1) }
        .contentShape(Rectangle())
    }
}

@MainActor
private struct SigningStatusCard: View {
    let status: SigningStatus
    let now: Date

    var body: some View {
        switch status {
        case .loading:
            ProgressView("正在读取签名信息…")
        case let .unavailable(reason):
            Label("无法确定签名到期时间", systemImage: "questionmark.shield").font(.headline)
            Text(reason).font(.footnote).foregroundStyle(.secondary)
        case let .available(profile):
            let urgency = SigningUrgency.resolve(expiration: profile.expirationDate, now: now)
            VStack(alignment: .leading, spacing: 8) {
                Label(urgency == .expired ? "描述文件已到期" : "签名剩余时间", systemImage: urgency.icon)
                    .font(.subheadline).foregroundStyle(.secondary)
                Text(SigningCountdown.text(expiration: profile.expirationDate, now: now))
                    .font(.title2.bold()).monospacedDigit().foregroundStyle(urgency.color)
                Text("到期时间：\(profile.expirationDate.formatted(date: .numeric, time: .shortened))")
                    .font(.footnote).textSelection(.enabled)
                Text("时区：\(TimeZone.current.identifier)").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            Text("请在到期前通过 Xcode 刷新签名并覆盖安装。不要先卸载 App，以免删除离线歌曲。")
                .font(.footnote).foregroundStyle(urgency == .normal ? Color.secondary : urgency.color)
        }
    }
}

@MainActor
private struct SigningDetailsView: View {
    @EnvironmentObject private var signing: SigningStatusModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        SigningStatusCard(status: signing.status, now: context.date)
                    }
                } header: { Text("当前安装版本") } footer: {
                    Text("依据描述文件到期时间和手机时间计算，不按安装日期加七天。证书撤销等情况可能提前影响使用；此处不是系统签名有效性验证，也不会自动续签。")
                }
                Section("到期提醒") {
                    Toggle("到期前提醒", isOn: Binding(
                        get: { signing.reminderEnabled }, set: { signing.setReminderEnabled($0) }
                    ))
                    .disabled(signing.status.expirationDate == nil && !signing.reminderEnabled)
                    .accessibilityIdentifier("signing.reminder-toggle")
                    if signing.isUpdatingReminders {
                        ProgressView("正在更新提醒…").font(.footnote)
                    } else {
                        Text(reminderDescription).font(.footnote).foregroundStyle(.secondary)
                    }
                    if signing.reminderEnabled && signing.report?.permission == .denied {
                        Button("前往系统设置开启通知") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                    }
                    if signing.reminderEnabled && signing.report?.permission == .notDetermined {
                        Button("允许到期通知") { signing.setReminderEnabled(true) }
                    }
                    if let error = signing.report?.error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                    Button("重新检查签名与提醒") { signing.activate(forceReload: true) }
                        .disabled(signing.isReading || signing.isUpdatingReminders)
                }
                #if DEBUG
                Section("预览") {
                    NavigationLink("查看提醒样式（演示）") { SigningPreviewGallery() }
                        .accessibilityIdentifier("signing.preview")
                }
                #endif
            }
            .navigationTitle("签名有效期")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }

    private var reminderDescription: String {
        guard signing.reminderEnabled else { return "开启后，在到期前 48 小时、24 小时提醒。无需连接音乐服务器。" }
        guard signing.status.expirationDate != nil else { return "无法确定到期时间，未安排通知。" }
        guard let report = signing.report else { return "正在检查通知权限。" }
        switch report.permission {
        case .denied: return "通知权限未开启；App 内倒计时仍然有效。"
        case .notDetermined: return "尚未授权，请点击允许到期通知。"
        case .unavailable: return "当前系统无法提供通知权限状态。"
        case .authorized, .quiet:
            let quiet = report.permission == .quiet ? "当前通知可能静默送达。" : ""
            guard !report.scheduled.isEmpty else {
                return "没有待发送的到期提醒；已错过的 48/24 小时提醒不会补发。" + quiet
            }
            let hours = report.scheduled.map { "\($0.hoursBefore) 小时" }.joined(separator: "、")
            return "已安排到期前 \(hours) 的本地提醒。通知展示仍受系统设置和专注模式影响。" + quiet
        }
    }
}

#if DEBUG
@MainActor
private struct SigningPreviewGallery: View {
    private let now = Date()
    private func sample(hours: Double) -> SigningStatus {
        .available(SigningProfile(expirationDate: now.addingTimeInterval(hours * 3600),
                                  creationDate: nil, identifier: "demo-only"))
    }
    var body: some View {
        List {
            Section { Text("以下均为演示数据，不代表当前签名，不修改真实日期，也不会发送通知。") }
            Section("正常 · 超过 48 小时") { SigningStatusCard(status: sample(hours: 74), now: now) }
            Section("临期 · 剩余 36 小时") { SigningCompactContent(status: sample(hours: 36), now: now) }
            Section("紧急 · 不足 24 小时") { SigningStatusCard(status: sample(hours: 8.5), now: now) }
            Section("已到期") { SigningStatusCard(status: sample(hours: -1), now: now) }
            Section("无法读取") {
                SigningStatusCard(status: .unavailable("模拟器或描述文件缺失时的显示效果。"), now: now)
            }
        }
        .navigationTitle("提醒样式（演示）")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
#endif
