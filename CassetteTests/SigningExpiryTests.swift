import Foundation
import XCTest
#if canImport(Cassette)
@testable import Cassette
#else
@testable import CassetteSigningCore
#endif

private let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

// Synthetic metadata only. No developer certificate, device ID or real profile.
private func tlv(_ tag: UInt8, _ payload: Data) -> Data {
    var result = Data([tag])
    let count = payload.count
    if count < 128 { result.append(UInt8(count)) }
    else if count < 256 { result.append(contentsOf: [0x81, UInt8(count)]) }
    else if count < 65536 { result.append(contentsOf: [0x82, UInt8(count >> 8), UInt8(count & 255)]) }
    else { fatalError("Test fixture is too large") }
    result.append(payload)
    return result
}

private func indefinite(_ tag: UInt8, _ payload: Data) -> Data {
    Data([tag, 0x80]) + payload + Data([0, 0])
}

private func fixture(expiration: Date = referenceDate.addingTimeInterval(7 * 86400),
                     appID: String? = "TESTTEAM.com.anxiong.cassette",
                     creation: Date? = referenceDate,
                     format: PropertyListSerialization.PropertyListFormat = .xml,
                     chunked: Bool = false,
                     omitExpiration: Bool = false) throws -> Data {
    var plist: [String: Any] = ["UUID": "synthetic-test-only"]
    if !omitExpiration { plist["ExpirationDate"] = expiration }
    if let creation { plist["CreationDate"] = creation }
    if let appID { plist["Entitlements"] = ["application-identifier": appID] }
    let payload = try PropertyListSerialization.data(fromPropertyList: plist, format: format, options: 0)
    let content: Data
    if chunked {
        let midpoint = payload.count / 2
        content = indefinite(0x24, tlv(0x04, payload.prefix(midpoint)) + tlv(0x04, payload.suffix(from: midpoint)))
    } else { content = tlv(0x04, payload) }
    let dataOID = tlv(0x06, Data([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x01]))
    let signedOID = tlv(0x06, Data([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x02]))
    let encapsulated = tlv(0x30, dataOID + tlv(0xa0, content))
    let signed = tlv(0x30, tlv(0x02, Data([1])) + tlv(0x31, Data()) + encapsulated + tlv(0x31, Data()))
    let body = signedOID + tlv(0xa0, signed)
    return chunked ? indefinite(0x30, body) : tlv(0x30, body)
}

final class SigningProfileTests: XCTestCase {
    func testXMLDateComesFromProfileNotInstallTime() throws {
        let profile = try SigningProfileReader.parse(fixture(), bundleIdentifier: "com.anxiong.cassette")
        XCTAssertEqual(profile.expirationDate, referenceDate.addingTimeInterval(7 * 86400))
        XCTAssertEqual(profile.creationDate, referenceDate)
    }
    func testBinaryPlist() throws {
        let profile = try SigningProfileReader.parse(fixture(format: .binary))
        XCTAssertEqual(profile.identifier, "synthetic-test-only")
    }
    func testBERIndefiniteChunkedContent() throws {
        let profile = try SigningProfileReader.parse(fixture(chunked: true))
        XCTAssertEqual(profile.expirationDate, referenceDate.addingTimeInterval(7 * 86400))
    }
    func testWrongBundleIdentifierIsRejected() throws {
        XCTAssertThrowsError(try SigningProfileReader.parse(fixture(), bundleIdentifier: "com.anxiong.nicevideos"))
    }
    func testMissingApplicationEntitlementIsRejectedForInstalledApp() throws {
        XCTAssertThrowsError(try SigningProfileReader.parse(fixture(appID: nil), bundleIdentifier: "com.anxiong.cassette"))
    }
    func testWildcardMatchesOnlyItsPrefix() throws {
        let data = try fixture(appID: "TESTTEAM.com.anxiong.*")
        XCTAssertNoThrow(try SigningProfileReader.parse(data, bundleIdentifier: "com.anxiong.cassette"))
        XCTAssertThrowsError(try SigningProfileReader.parse(data, bundleIdentifier: "com.anxiong2.cassette"))
    }
    func testMissingExpiryIsUnknown() throws {
        XCTAssertThrowsError(try SigningProfileReader.parse(fixture(omitExpiration: true)))
    }
    func testInvertedDatesAreRejected() throws {
        XCTAssertThrowsError(try SigningProfileReader.parse(fixture(expiration: referenceDate)))
    }
    func testExpiredProfileStillReportsItsActualDate() throws {
        let date = referenceDate.addingTimeInterval(-3600)
        let profile = try SigningProfileReader.parse(fixture(expiration: date, creation: nil))
        XCTAssertEqual(SigningUrgency.resolve(expiration: profile.expirationDate, now: referenceDate), .expired)
    }
    func testEmptyTruncatedAndTrailingDataAreRejected() throws {
        let good = try fixture()
        for data in [Data(), Data(good.dropLast()), good + Data([0]), Data([0x30, 0x84, 0xff, 0xff, 0xff, 0xff])] {
            XCTAssertThrowsError(try SigningProfileReader.parse(data))
        }
    }
    func testOversizedAndDeeplyNestedInputsAreBounded() {
        XCTAssertThrowsError(try SigningProfileReader.parse(Data(repeating: 0, count: SigningProfileReader.maximumSize + 1)))
        var nested = tlv(0x02, Data([1]))
        for _ in 0..<30 { nested = indefinite(0x30, nested) }
        XCTAssertThrowsError(try SigningProfileReader.parse(nested))
    }
    func testRawXMLIsNotMistakenForCMS() throws {
        let xml = try PropertyListSerialization.data(fromPropertyList: ["ExpirationDate": referenceDate], format: .xml, options: 0)
        XCTAssertThrowsError(try SigningProfileReader.parse(xml))
    }
}

final class SigningCountdownTests: XCTestCase {
    func testDaysAndHoursRoundDown() {
        XCTAssertEqual(SigningCountdown.text(expiration: referenceDate.addingTimeInterval(54 * 3600 + 59), now: referenceDate), "2 天 6 小时")
    }
    func testLessThanADayShowsHoursAndMinutes() {
        XCTAssertEqual(SigningCountdown.text(expiration: referenceDate.addingTimeInterval(8 * 3600 + 30 * 60), now: referenceDate), "8 小时 30 分钟")
        XCTAssertEqual(SigningCountdown.text(expiration: referenceDate.addingTimeInterval(59), now: referenceDate), "不足 1 分钟")
    }
    func testExactUrgencyBoundaries() {
        for (seconds, expected) in [(172801.0, SigningUrgency.normal), (172800, .warning), (86401, .warning), (86400, .urgent), (1, .urgent), (0, .expired), (-1, .expired)] {
            XCTAssertEqual(SigningUrgency.resolve(expiration: referenceDate.addingTimeInterval(seconds), now: referenceDate), expected)
        }
        XCTAssertEqual(SigningCountdown.text(expiration: referenceDate, now: referenceDate), "已到期")
    }
    func testUnknownAndExpiredDoNotSchedule() {
        XCTAssertTrue(SigningReminderPlan.requests(expiration: nil, now: referenceDate).isEmpty)
        XCTAssertTrue(SigningReminderPlan.requests(expiration: referenceDate, now: referenceDate).isEmpty)
    }
    func testReminderDatesAndMusicNamespace() {
        let expiry = referenceDate.addingTimeInterval(7 * 86400)
        let requests = SigningReminderPlan.requests(expiration: expiry, now: referenceDate)
        XCTAssertEqual(requests.map(\.hoursBefore), [48, 24])
        XCTAssertTrue(requests.allSatisfy { $0.identifier.hasPrefix("cassette.") })
        XCTAssertEqual(requests.first?.fireDate, expiry.addingTimeInterval(-48 * 3600))
        XCTAssertEqual(requests.last?.fireDate, expiry.addingTimeInterval(-24 * 3600))
    }
    func testMissedRemindersAreNotReplayed() {
        XCTAssertEqual(SigningReminderPlan.requests(expiration: referenceDate.addingTimeInterval(36 * 3600), now: referenceDate).map(\.hoursBefore), [24])
        XCTAssertTrue(SigningReminderPlan.requests(expiration: referenceDate.addingTimeInterval(24 * 3600), now: referenceDate).isEmpty)
    }
}

private actor FakeNotifications: SigningNotificationClient {
    var state: SigningNotificationPermission
    var pending: [String: SigningReminderRequest] = [:]
    var prompts = 0
    var adds = 0
    let failAt: Int?
    let delay: Bool
    private var firstAddWaiter: CheckedContinuation<Void, Never>?
    private var firstAddGate: CheckedContinuation<Void, Never>?
    private var firstAddReached = false

    init(_ permission: SigningNotificationPermission = .authorized, failAt: Int? = nil, delay: Bool = false) {
        state = permission; self.failAt = failAt; self.delay = delay
    }
    func permission() async -> SigningNotificationPermission { state }
    func requestPermission() async throws { prompts += 1; state = .authorized }
    func clear(identifiers: [String]) async { for id in identifiers { pending.removeValue(forKey: id) } }
    func add(_ request: SigningReminderRequest) async throws -> Bool {
        adds += 1
        if delay && adds == 1 {
            firstAddReached = true
            firstAddWaiter?.resume(); firstAddWaiter = nil
            await withCheckedContinuation { firstAddGate = $0 }
        }
        if adds == failAt { throw NSError(domain: "SyntheticAddFailure", code: 1) }
        pending[request.identifier] = request
        return true
    }
    func waitForFirstAdd() async {
        if !firstAddReached { await withCheckedContinuation { firstAddWaiter = $0 } }
    }
    func releaseFirstAdd() { firstAddGate?.resume(); firstAddGate = nil }
    func seed(_ request: SigningReminderRequest) { pending[request.identifier] = request }
    func values() -> [SigningReminderRequest] { Array(pending.values) }
    func promptCount() -> Int { prompts }
}

final class SigningReminderTests: XCTestCase {
    @MainActor
    func testStartupNeverPromptsForPermission() async {
        let client = FakeNotifications(.notDetermined)
        let scheduler = SigningReminderScheduler(client: client)
        let report = await scheduler.synchronize(expiration: referenceDate.addingTimeInterval(7 * 86400), enabled: true, now: { referenceDate }).value
        let prompts = await client.promptCount()
        XCTAssertEqual(prompts, 0)
        XCTAssertTrue(report.scheduled.isEmpty)
    }
    @MainActor
    func testExplicitEnableAsksPermissionAndSchedules() async {
        let client = FakeNotifications(.notDetermined)
        let scheduler = SigningReminderScheduler(client: client)
        let report = await scheduler.synchronize(expiration: referenceDate.addingTimeInterval(7 * 86400), enabled: true, requestPermission: true, now: { referenceDate }).value
        let prompts = await client.promptCount()
        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(report.scheduled.count, 2)
    }
    @MainActor
    func testDeniedPermissionDoesNotSchedule() async {
        let client = FakeNotifications(.denied)
        let scheduler = SigningReminderScheduler(client: client)
        let report = await scheduler.synchronize(expiration: referenceDate.addingTimeInterval(7 * 86400), enabled: true, requestPermission: true, now: { referenceDate }).value
        XCTAssertEqual(report.permission, .denied)
        XCTAssertTrue(report.scheduled.isEmpty)
    }
    @MainActor
    func testResigningReplacesBothDates() async {
        let client = FakeNotifications()
        let scheduler = SigningReminderScheduler(client: client)
        let old = referenceDate.addingTimeInterval(3 * 86400)
        let new = referenceDate.addingTimeInterval(7 * 86400)
        _ = await scheduler.synchronize(expiration: old, enabled: true, now: { referenceDate }).value
        _ = await scheduler.synchronize(expiration: new, enabled: true, now: { referenceDate }).value
        let pending = await client.values()
        XCTAssertEqual(pending.count, 2)
        XCTAssertTrue(pending.allSatisfy { $0.expirationDate == new })
    }
    @MainActor
    func testDisableAndUnknownClearOnlySigningReminders() async {
        let client = FakeNotifications()
        let scheduler = SigningReminderScheduler(client: client)
        let expiry = referenceDate.addingTimeInterval(7 * 86400)
        let unrelated = SigningReminderRequest(identifier: "cassette.other-notification", fireDate: expiry, expirationDate: expiry, hoursBefore: 0)
        await client.seed(unrelated)
        _ = await scheduler.synchronize(expiration: expiry, enabled: true, now: { referenceDate }).value
        _ = await scheduler.synchronize(expiration: nil, enabled: true, now: { referenceDate }).value
        var pending = await client.values()
        XCTAssertEqual(pending, [unrelated])
        _ = await scheduler.synchronize(expiration: expiry, enabled: true, now: { referenceDate }).value
        _ = await scheduler.synchronize(expiration: expiry, enabled: false, now: { referenceDate }).value
        pending = await client.values()
        XCTAssertEqual(pending, [unrelated])
    }
    @MainActor
    func testDisableQueuedDuringAddCannotRestoreReminders() async {
        let client = FakeNotifications(delay: true)
        let scheduler = SigningReminderScheduler(client: client)
        let expiry = referenceDate.addingTimeInterval(7 * 86400)
        let enable = scheduler.synchronize(expiration: expiry, enabled: true, now: { referenceDate })
        await client.waitForFirstAdd()
        let disable = scheduler.synchronize(expiration: expiry, enabled: false, now: { referenceDate })
        await client.releaseFirstAdd()
        _ = await enable.value
        let report = await disable.value
        let pending = await client.values()
        XCTAssertTrue(report.scheduled.isEmpty)
        XCTAssertTrue(pending.isEmpty)
    }
    @MainActor
    func testPartialAddFailureRollsBack() async {
        let client = FakeNotifications(failAt: 2)
        let scheduler = SigningReminderScheduler(client: client)
        let report = await scheduler.synchronize(expiration: referenceDate.addingTimeInterval(7 * 86400), enabled: true, now: { referenceDate }).value
        let pending = await client.values()
        XCTAssertNotNil(report.error)
        XCTAssertTrue(report.scheduled.isEmpty)
        XCTAssertTrue(pending.isEmpty)
    }
}
