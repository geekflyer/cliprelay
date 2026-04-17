import XCTest
@testable import ClipRelay

final class TelemetryManagerTests: XCTestCase {
    private var defaults: UserDefaults!
    private let defaultsSuiteName = "org.cliprelay.tests.telemetry.\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: defaultsSuiteName)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaults = nil
        super.tearDown()
    }

    func testResolveInstallIdPrefersExistingDefaultsValue() {
        let expected = "existing-defaults-id"
        defaults.set(expected, forKey: "telemetry_install_id")

        let resolved = TelemetryManager.resolveInstallId(
            defaults: defaults,
            legacyStore: InMemoryDataStore()
        )

        XCTAssertEqual(resolved, expected)
        XCTAssertEqual(defaults.string(forKey: "telemetry_install_id"), expected)
    }

    func testResolveInstallIdMigratesLegacyKeychainValueIntoDefaults() {
        let legacyId = "legacy-keychain-id"
        let legacyStore = InMemoryDataStore()
        legacyStore.setData(Data(legacyId.utf8), for: "telemetry_install_id")

        let resolved = TelemetryManager.resolveInstallId(
            defaults: defaults,
            legacyStore: legacyStore
        )

        XCTAssertEqual(resolved, legacyId)
        XCTAssertEqual(defaults.string(forKey: "telemetry_install_id"), legacyId)
    }
}
