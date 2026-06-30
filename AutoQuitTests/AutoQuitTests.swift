import XCTest
@testable import AutoQuit

final class AutoQuitTests: XCTestCase {

    // MARK: Idle/terminate boundary (the "quit too early / too late" surface)

    func testShouldQuitBoundary() {
        let hours = 8
        let threshold = Double(hours * 3600)
        XCTAssertFalse(QuitDecision.shouldQuit(idle: threshold - 1, thresholdHours: hours,
                                               isFinishedLaunching: true, optedOut: false))
        XCTAssertFalse(QuitDecision.shouldQuit(idle: threshold, thresholdHours: hours,
                                               isFinishedLaunching: true, optedOut: false),
                       "exactly at the threshold must not quit (strict >)")
        XCTAssertTrue(QuitDecision.shouldQuit(idle: threshold + 1, thresholdHours: hours,
                                              isFinishedLaunching: true, optedOut: false))
    }

    func testShouldQuitRespectsOptOutAndLaunchState() {
        let over = Double(8 * 3600) + 60
        XCTAssertFalse(QuitDecision.shouldQuit(idle: over, thresholdHours: 8,
                                               isFinishedLaunching: true, optedOut: true),
                       "an opted-out app must never be quit")
        XCTAssertFalse(QuitDecision.shouldQuit(idle: over, thresholdHours: 8,
                                               isFinishedLaunching: false, optedOut: false),
                       "an app that hasn't finished launching must never be quit")
    }

    // MARK: Per-app timeout resolution

    func testEffectiveHoursResolution() {
        // Per-app override wins over the global timeout.
        XCTAssertEqual(QuitDecision.effectiveHours(perApp: ["com.x": 4], key: "com.x", global: 8), 4)
        // No override for this key → falls back to the global timeout.
        XCTAssertEqual(QuitDecision.effectiveHours(perApp: [:], key: "com.x", global: 8), 8)
        XCTAssertEqual(QuitDecision.effectiveHours(perApp: ["com.y": 4], key: "com.x", global: 8), 8)
        // Excluded app never quits, whatever its effective timeout resolves to.
        let hours = QuitDecision.effectiveHours(perApp: [:], key: "com.x", global: 8)
        XCTAssertFalse(QuitDecision.shouldQuit(idle: Double(hours * 3600) + 60, thresholdHours: hours,
                                               isFinishedLaunching: true, optedOut: true),
                       "an excluded app must never quit regardless of its effective timeout")
    }

    // MARK: Countdown formatting
    //
    // IdleTime uses a locale-aware Duration formatter, so the tests pin en_US to keep
    // the asserted strings deterministic on any host/CI (an unpinned locale makes
    // nl/fr/de/en_CA hosts produce "1 m"/"1min" and fail). The behavior contract being
    // verified: seconds appear only under a minute, and zero units are dropped (no
    // "1h 0m"). The boundary points (0, 59, 60, 3600, 3661) are called out in the spec.

    private let en = Locale(identifier: "en_US")

    func testIdleTimeShort() {
        XCTAssertEqual(IdleTime.short(0, locale: en), "0s")
        XCTAssertEqual(IdleTime.short(59, locale: en), "59s")
        XCTAssertEqual(IdleTime.short(60, locale: en), "1m")
        XCTAssertEqual(IdleTime.short(3600, locale: en), "1h")
        XCTAssertEqual(IdleTime.short(3661, locale: en), "1h 1m")
        XCTAssertEqual(IdleTime.short(7 * 3600 + 32 * 60, locale: en), "7h 32m")
        XCTAssertEqual(IdleTime.short(8 * 3600, locale: en), "8h")
        XCTAssertEqual(IdleTime.short(45 * 60, locale: en), "45m")
        XCTAssertEqual(IdleTime.short(3600 + 59, locale: en), "1h", "leftover seconds under a minute are dropped, not rounded up")
        XCTAssertEqual(IdleTime.short(-100, locale: en), "0s")
    }

    func testIdleTimeVerbose() {
        XCTAssertEqual(IdleTime.verbose(0, locale: en), "0 seconds")
        XCTAssertEqual(IdleTime.verbose(59, locale: en), "59 seconds")
        XCTAssertEqual(IdleTime.verbose(60, locale: en), "1 minute")
        XCTAssertEqual(IdleTime.verbose(3600, locale: en), "1 hour")
        XCTAssertEqual(IdleTime.verbose(3600 + 60, locale: en), "1 hour, 1 minute")
        XCTAssertEqual(IdleTime.verbose(2 * 3600 + 5 * 60, locale: en), "2 hours, 5 minutes")
    }
}
