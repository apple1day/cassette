import Foundation
import XCTest
#if canImport(CassetteSigningCore)
@testable import CassetteSigningCore
#else
@testable import Cassette
#endif

// Synthetic metadata only: no real profile, certificate, device ID or private key.
private nonisolated enum ProfileFixture {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static let expiry = now.addingTimeInterval(7 * 86_400)
    static var plist: [String: Any] {
        ["ExpirationDate": expiry, "CreationDate": now, "UUID": "synthetic-profile",
         "Entitlements": ["application-identifier": "TESTTEAM.com.anxiong.cassette"]]
    }
    static func tlv(_ tag: UInt8, _ value: Data) -> Data {
        var length = value.count
        if length < 128 { return Data([tag, UInt8(length)]) + value }
        var bytes: [UInt8] = []
        while length > 0 { bytes.insert(UInt8(length & 255), at: 0); length >>= 8 }
        return Data([tag, 0x80 | UInt8(bytes.count)] + bytes) + value
    }
    static func cms(_ plist: [String: Any] = plist,
                    format: PropertyListSerialization.PropertyListFormat = .xml,
                    indefinite: Bool = false, chunked: Bool = false) throws -> Data {
        let payload = try PropertyListSerialization.data(fromPropertyList: plist, format: format, options: 0)
        let content: Data
        if chunked {
            let middle = payload.count / 2
            let parts = tlv(0x04, Data(payload[..<middle])) + tlv(0x04, Data(payload[middle...]))
            content = Data([0x24, 0x80]) + parts + Data([0, 0])
        } else { content = tlv(0x04, payload) }
        let oid = Data([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07])
        let encap = tlv(0x30, tlv(0x06, oid + Data([1])) + tlv(0xa0, content))
        let signed = tlv(0x30, Data([2, 1, 1, 0x31, 0]) + encap + Data([0x31, 0]))
        let body = tlv(0x06, oid + Data([2])) + tlv(0xa0, signed)
        return indefinite ? Data([0x30, 0x80]) + body + Data([0, 0]) : tlv(0x30, body)
    }
}

nonisolated final class SigningExpiryTests: XCTestCase {
    func testXMLProfile() throws {
        let profile = try SigningProfileReader.parse(ProfileFixture.cms(), bundleIdentifier: "com.anxiong.cassette")
        XCTAssertEqual(profile.expirationDate, ProfileFixture.expiry)
        XCTAssertEqual(profile.creationDate, ProfileFixture.now)
        XCTAssertEqual(profile.identifier, "synthetic-profile")
    }
    func testBinaryProfile() throws {
        XCTAssertEqual(try SigningProfileReader.parse(ProfileFixture.cms(format: .binary)).expirationDate, ProfileFixture.expiry)
    }
    func testIndefiniteBER() throws {
        XCTAssertEqual(try SigningProfileReader.parse(ProfileFixture.cms(indefinite: true)).expirationDate, ProfileFixture.expiry)
    }
    func testChunkedContent() throws {
        XCTAssertEqual(try SigningProfileReader.parse(ProfileFixture.cms(format: .binary, indefinite: true, chunked: true)).expirationDate, ProfileFixture.expiry)
    }
    func testMissingOrStringExpiryRejected() throws {
        for value in [nil, "2026-09-30"] as [String?] {
            var plist = ProfileFixture.plist
            plist["ExpirationDate"] = value
            XCTAssertThrowsError(try SigningProfileReader.parse(ProfileFixture.cms(plist)))
        }
    }
    func testInvalidCreationDateRejected() throws {
        var plist = ProfileFixture.plist
        plist["CreationDate"] = ProfileFixture.expiry
        XCTAssertThrowsError(try SigningProfileReader.parse(ProfileFixture.cms(plist)))
    }
    func testWrongApplicationRejected() throws {
        XCTAssertThrowsError(try SigningProfileReader.parse(ProfileFixture.cms(), bundleIdentifier: "com.other.app"))
    }
    func testWildcardApplication() throws {
        for pattern in ["TESTTEAM.*", "TESTTEAM.com.anxiong.*"] {
            var plist = ProfileFixture.plist
            plist["Entitlements"] = ["application-identifier": pattern]
            XCTAssertNoThrow(try SigningProfileReader.parse(ProfileFixture.cms(plist), bundleIdentifier: "com.anxiong.cassette"))
        }
    }
    func testWildcardCannotMatchSiblingPrefix() throws {
        var plist = ProfileFixture.plist
        plist["Entitlements"] = ["application-identifier": "TESTTEAM.com.anxiong.*"]
        XCTAssertThrowsError(try SigningProfileReader.parse(ProfileFixture.cms(plist), bundleIdentifier: "com.anxiong2.cassette"))
    }
    func testUnwrappedXMLRejected() throws {
        let payload = try PropertyListSerialization.data(fromPropertyList: ProfileFixture.plist, format: .xml, options: 0)
        XCTAssertThrowsError(try SigningProfileReader.parse(payload))
    }
    func testOversizedAndDeepInputsRejected() throws {
        XCTAssertThrowsError(try SigningProfileReader.parse(Data(repeating: 0, count: SigningProfileReader.maximumSize + 1)))
        var deep = Data([2, 1, 1])
        for _ in 0..<25 { deep = ProfileFixture.tlv(0x30, deep) }
        XCTAssertThrowsError(try SigningProfileReader.parse(deep))
    }
    func testTruncatedInputsAndTrailingBytesRejected() throws {
        let data = try ProfileFixture.cms()
        for length in stride(from: 0, to: data.count, by: 13) {
            XCTAssertThrowsError(try SigningProfileReader.parse(Data(data.prefix(length))))
        }
        XCTAssertThrowsError(try SigningProfileReader.parse(data + Data([0])))
        XCTAssertThrowsError(try SigningProfileReader.parse(Data([0x30, 0x84, 0xff, 0xff, 0xff, 0xff])))
    }
    func testProfileDateIsNotInstallationDatePlusSevenDays() throws {
        let data = try ProfileFixture.cms()
        let first = try SigningProfileReader.parse(data)
        let reinstalled = try SigningProfileReader.parse(data)
        XCTAssertEqual(first.expirationDate, reinstalled.expirationDate)
        XCTAssertEqual(SigningCountdown.text(expiration: first.expirationDate,
                                            now: ProfileFixture.now.addingTimeInterval(5 * 86_400)), "2 天 0 小时")
    }
    func testCountdownBoundaries() {
        let cases: [(TimeInterval, String)] = [(0, "已到期"), (-1, "已到期"), (59, "不足 1 分钟"),
            (60, "1 分钟"), (3599, "59 分钟"), (3600, "1 小时 0 分钟"),
            (86399, "23 小时 59 分钟"), (86400, "1 天 0 小时"), (194400, "2 天 6 小时")]
        for (seconds, expected) in cases {
            XCTAssertEqual(SigningCountdown.text(expiration: ProfileFixture.now.addingTimeInterval(seconds),
                                                now: ProfileFixture.now), expected)
        }
    }
    func testUrgencyBoundaries() {
        let cases: [(TimeInterval, SigningUrgency)] = [(0, .expired), (1, .urgent),
            (86400, .urgent), (86401, .warning), (172800, .warning), (172801, .normal)]
        for (seconds, expected) in cases {
            XCTAssertEqual(SigningUrgency.resolve(expiration: ProfileFixture.now.addingTimeInterval(seconds),
                                                 now: ProfileFixture.now), expected)
        }
    }
    func testUnknownDateIsNotPermanent() {
        XCTAssertNil(SigningStatus.unavailable("missing").expirationDate)
        XCTAssertEqual(SigningCountdown.text(expiration: Date(timeIntervalSince1970: .infinity),
                                            now: ProfileFixture.now), "无法确定")
    }
    func testReminderDatesAndNamespace() {
        let requests = SigningReminderPlan.requests(expiration: ProfileFixture.expiry, now: ProfileFixture.now)
        XCTAssertEqual(requests.map(\.hoursBefore), [48, 24])
        XCTAssertEqual(requests.map(\.identifier), ["cassette.signing-expiry.48h", "cassette.signing-expiry.24h"])
        XCTAssertEqual(requests.map { $0.expirationDate.timeIntervalSince($0.fireDate) }, [172800, 86400])
    }
    func testMissedRemindersNotReplayed() {
        XCTAssertEqual(SigningReminderPlan.requests(expiration: ProfileFixture.now.addingTimeInterval(30 * 3600),
                                                   now: ProfileFixture.now).map(\.hoursBefore), [24])
        for date in [nil, ProfileFixture.now, ProfileFixture.now.addingTimeInterval(24 * 3600)] as [Date?] {
            XCTAssertTrue(SigningReminderPlan.requests(expiration: date, now: ProfileFixture.now).isEmpty)
        }
    }
}

private actor FakeSigningNotifications: SigningNotificationClient {
    var authorization: SigningNotificationPermission
    var pending: [String: SigningReminderRequest] = [:]
    var promptCount = 0
    var addCount = 0
    var failOnAdd: Int?
    var holdPrompt = false
    var continuation: CheckedContinuation<Void, Never>?
    let promptOpened: (@Sendable () -> Void)?

    init(_ authorization: SigningNotificationPermission = .authorized,
         promptOpened: (@Sendable () -> Void)? = nil) {
        self.authorization = authorization
        self.promptOpened = promptOpened
    }
    func permission() async -> SigningNotificationPermission { authorization }
    func requestPermission() async throws {
        promptCount += 1
        if holdPrompt {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                promptOpened?()
            }
        }
        authorization = .authorized
    }
    func clear(identifiers: [String]) async {
        for id in identifiers { pending.removeValue(forKey: id) }
    }
    func add(_ request: SigningReminderRequest) async throws -> Bool {
        addCount += 1
        if failOnAdd == addCount { throw NSError(domain: "SyntheticAddFailure", code: 1) }
        pending[request.identifier] = request
        return true
    }
    func setFailure(_ number: Int) { failOnAdd = number }
    func blockPrompt() { holdPrompt = true }
    func releasePrompt() { continuation?.resume(); continuation = nil }
    func snapshot() -> [String: SigningReminderRequest] { pending }
    func counts() -> (prompts: Int, adds: Int) { (promptCount, addCount) }
}

nonisolated final class SigningReminderTests: XCTestCase {
    private func sync(_ scheduler: SigningReminderScheduler, date: Date? = ProfileFixture.expiry,
                      enabled: Bool = true, ask: Bool = false) async -> SigningReminderReport {
        let task = await scheduler.synchronize(expiration: date, enabled: enabled,
                                               requestPermission: ask, now: { ProfileFixture.now })
        return await task.value
    }
    func testAuthorizedSchedulesTwo() async {
        let client = FakeSigningNotifications()
        let scheduler = await SigningReminderScheduler(client: client)
        let result = await sync(scheduler)
        XCTAssertEqual(result.scheduled.count, 2)
        XCTAssertNil(result.error)
    }
    func testStartupNeverRequestsPermission() async {
        let client = FakeSigningNotifications(.notDetermined)
        let scheduler = await SigningReminderScheduler(client: client)
        let result = await sync(scheduler)
        let counts = await client.counts()
        XCTAssertTrue(result.scheduled.isEmpty)
        XCTAssertEqual(counts.prompts, 0)
    }
    func testExplicitOptInRequestsPermission() async {
        let client = FakeSigningNotifications(.notDetermined)
        let scheduler = await SigningReminderScheduler(client: client)
        let result = await sync(scheduler, ask: true)
        let counts = await client.counts()
        XCTAssertEqual(result.scheduled.count, 2)
        XCTAssertEqual(counts.prompts, 1)
    }
    func testDeniedDoesNotPromptAgain() async {
        let client = FakeSigningNotifications(.denied)
        let scheduler = await SigningReminderScheduler(client: client)
        let result = await sync(scheduler, ask: true)
        let counts = await client.counts()
        XCTAssertEqual(result.permission, .denied)
        XCTAssertTrue(result.scheduled.isEmpty)
        XCTAssertEqual(counts.prompts, 0)
    }
    func testQuietPermissionSchedules() async {
        let client = FakeSigningNotifications(.quiet)
        let scheduler = await SigningReminderScheduler(client: client)
        let result = await sync(scheduler)
        XCTAssertEqual(result.scheduled.count, 2)
    }
    func testRenewalReplacesOldDates() async {
        let client = FakeSigningNotifications()
        let scheduler = await SigningReminderScheduler(client: client)
        _ = await sync(scheduler)
        let renewed = ProfileFixture.expiry.addingTimeInterval(3 * 86400)
        _ = await sync(scheduler, date: renewed)
        let pending = await client.snapshot()
        XCTAssertEqual(pending.count, 2)
        XCTAssertTrue(pending.values.allSatisfy { $0.expirationDate == renewed })
    }
    func testDisablePreservesOtherNotifications() async throws {
        let client = FakeSigningNotifications()
        let other = SigningReminderRequest(identifier: "cassette.other", fireDate: ProfileFixture.expiry,
                                           expirationDate: ProfileFixture.expiry, hoursBefore: 0)
        _ = try await client.add(other)
        let scheduler = await SigningReminderScheduler(client: client)
        _ = await sync(scheduler)
        _ = await sync(scheduler, enabled: false)
        let pending = await client.snapshot()
        XCTAssertEqual(pending, [other.identifier: other])
    }
    func testMissingProfileClearsOldReminders() async {
        let client = FakeSigningNotifications()
        let scheduler = await SigningReminderScheduler(client: client)
        _ = await sync(scheduler)
        _ = await sync(scheduler, date: nil)
        let pending = await client.snapshot()
        XCTAssertTrue(pending.isEmpty)
    }
    func testPartialFailureRollsBack() async {
        let client = FakeSigningNotifications()
        await client.setFailure(2)
        let scheduler = await SigningReminderScheduler(client: client)
        let result = await sync(scheduler)
        let pending = await client.snapshot()
        XCTAssertTrue(pending.isEmpty)
        XCTAssertTrue(result.scheduled.isEmpty)
        XCTAssertNotNil(result.error)
    }
    func testDisableWhilePermissionDialogIsOpenWins() async {
        let opened = expectation(description: "permission requested")
        let client = FakeSigningNotifications(.notDetermined, promptOpened: { opened.fulfill() })
        await client.blockPrompt()
        let scheduler = await SigningReminderScheduler(client: client)
        let enable = await scheduler.synchronize(expiration: ProfileFixture.expiry, enabled: true,
                                                  requestPermission: true, now: { ProfileFixture.now })
        await fulfillment(of: [opened], timeout: 3)
        let disable = await scheduler.synchronize(expiration: ProfileFixture.expiry, enabled: false,
                                                   now: { ProfileFixture.now })
        await client.releasePrompt()
        _ = await enable.value
        _ = await disable.value
        let pending = await client.snapshot()
        let counts = await client.counts()
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(counts.adds, 0)
    }
}
