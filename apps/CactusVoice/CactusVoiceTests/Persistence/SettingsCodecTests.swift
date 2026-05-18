import XCTest
import Observation
@testable import CactusVoice

/// Runtime codec + storage + observability tests for `Settings` and
/// `SettingsStore` (Story 1.5 AC6).
@MainActor
final class SettingsCodecTests: XCTestCase {

    private let suite = "test.cactusvoice"
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        try await super.tearDown()
    }

    // MARK: - JSON round-trip

    func testJsonRoundTripWithNilPaths() throws {
        let original = Settings(
            hotkey: nil,
            activationMode: .hold,
            whisperModelPath: nil,
            llmModelPath: nil,
            whisperBookmark: nil,
            llmBookmark: nil
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testJsonRoundTripWithPopulatedFieldsAnd1KBBookmarks() throws {
        let bookmark = Data(repeating: 0x42, count: 1024)
        let original = Settings(
            hotkey: "captureToggle",
            activationMode: .toggle,
            whisperModelPath: "/tmp/whisper.bin",
            llmModelPath: "/tmp/gemma.bin",
            whisperBookmark: bookmark,
            llmBookmark: bookmark
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.whisperBookmark?.count, 1024)
        XCTAssertEqual(decoded.llmBookmark?.count, 1024)
    }

    // MARK: - UserDefaults round-trip

    func testStoreReadsAndWritesUserDefaults() throws {
        // Pre-seed UserDefaults so a fresh store reads it.
        let seeded = Settings(
            hotkey: "captureHold",
            activationMode: .toggle,
            whisperModelPath: "/tmp/w.bin",
            llmModelPath: nil,
            whisperBookmark: Data(repeating: 0x42, count: 1024),
            llmBookmark: nil
        )
        let blob = try JSONEncoder().encode(seeded)
        defaults.set(blob, forKey: SettingsKeys.blob)

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.current, seeded)

        // Mutate and confirm UserDefaults is updated synchronously.
        var next = store.current
        next.whisperModelPath = "/tmp/changed.bin"
        store.current = next

        let persisted = defaults.data(forKey: SettingsKeys.blob)
        XCTAssertNotNil(persisted)
        let decoded = try JSONDecoder().decode(Settings.self, from: persisted!)
        XCTAssertEqual(decoded.whisperModelPath, "/tmp/changed.bin")
    }

    func testStoreFallsBackWhenKeyMissing() {
        // UserDefaults is empty (cleared in setUp).
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.current, Settings())
        XCTAssertEqual(store.current.activationMode, .hold)
    }

    // MARK: - Defaults

    func testDefaultActivationModeIsHold() {
        XCTAssertEqual(Settings().activationMode, .hold)
    }

    // MARK: - Observability

    func testMutatingCurrentTriggersObservation() {
        let store = SettingsStore(defaults: defaults)
        let expectation = XCTestExpectation(description: "observation fires on mutate")

        withObservationTracking {
            // Touch the observable property so this scope is registered as a dependency.
            _ = store.current
        } onChange: {
            expectation.fulfill()
        }

        var next = store.current
        next.activationMode = .toggle
        store.current = next

        wait(for: [expectation], timeout: 1.0)
    }
}
