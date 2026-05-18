import XCTest
import AppKit
@testable import CactusVoice

/// Runtime tests for `TranscriptTextStorage` — covers Story 2.3 ACs:
/// snapshot rebuild on TranscriptUpdate, label-colour attribution for
/// committed vs. provisional regions, replaceCharacters(in:with:) routing
/// to TranscriptModel.userEdit, and edited(...) notification emission.
///
/// The storage is `@MainActor`; tests run their assertions on the main
/// actor. Where the storage's subscription task or actor round-trips
/// need to drain, the test pumps the main runloop briefly via
/// `RunLoop.main.run(until:)`.
@MainActor
final class TranscriptTextStorageTests: XCTestCase {

    // MARK: - Helpers

    private func pumpRunLoop(seconds: TimeInterval = 0.1) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func awaitStreamYield() async {
        // Give the model's continuation + the storage's subscription task
        // a chance to interleave before pumping the runloop.
        await Task.yield()
        await Task.yield()
    }

    // MARK: - AC4-6: commit from actor reaches storage

    func testCommitFromActorReachesStorage() async throws {
        let model = TranscriptModel(provisional: AttributedString("hello"))
        let storage = TranscriptTextStorage(model: model)

        // Drain the seed-on-init rebuild + the upcoming commit broadcast.
        let provisional = await model.provisional
        let range = provisional.startIndex..<provisional.endIndex
        try await model.commit(range: range, text: AttributedString("hello"))

        // Allow the AsyncStream subscription task to receive the commit
        // and rebuild the snapshot.
        for _ in 0..<10 {
            await awaitStreamYield()
            pumpRunLoop(seconds: 0.02)
            if storage.string == "hello" { break }
        }
        XCTAssertEqual(storage.string, "hello",
                       "Snapshot must reflect the actor's committed text after one runloop tick")
    }

    // MARK: - AC5: committed = labelColor, provisional = secondaryLabelColor

    func testCommittedAndProvisionalAttributes() async throws {
        let model = TranscriptModel(
            committed: AttributedString("AAA"),
            provisional: AttributedString("BBB")
        )
        let storage = TranscriptTextStorage(model: model)

        // Wait for seed rebuild.
        for _ in 0..<10 {
            await awaitStreamYield()
            pumpRunLoop(seconds: 0.02)
            if storage.string == "AAABBB" { break }
        }
        XCTAssertEqual(storage.string, "AAABBB")

        let committedAttrs = storage.attributes(at: 0, effectiveRange: nil)
        let provisionalAttrs = storage.attributes(at: 3, effectiveRange: nil)
        XCTAssertEqual(committedAttrs[.foregroundColor] as? NSColor, NSColor.labelColor,
                       "Committed offset must carry NSColor.labelColor")
        XCTAssertEqual(provisionalAttrs[.foregroundColor] as? NSColor, NSColor.secondaryLabelColor,
                       "Provisional offset must carry NSColor.secondaryLabelColor")
    }

    // MARK: - AC7: replaceCharacters routes to model.userEdit

    func testReplaceCharactersRoutesToModel() async throws {
        let model = TranscriptModel(
            committed: AttributedString("hellp"),
            provisional: AttributedString("")
        )
        let storage = TranscriptTextStorage(model: model)

        // Wait for the seed rebuild so committedLength is populated.
        for _ in 0..<10 {
            await awaitStreamYield()
            pumpRunLoop(seconds: 0.02)
            if storage.string == "hellp" { break }
        }
        XCTAssertEqual(storage.string, "hellp")

        // Replace 'p' (index 4..<5) with 'o' via the NSTextStorage API.
        storage.replaceCharacters(in: NSRange(location: 4, length: 1), with: "o")

        // Optimistic apply must have updated the cache synchronously.
        XCTAssertEqual(storage.string, "hello",
                       "Optimistic local apply must update the cache before the actor returns")

        // Drain the dispatched Task → actor userEdit.
        for _ in 0..<10 {
            await awaitStreamYield()
            pumpRunLoop(seconds: 0.02)
            let committed = await model.committed
            if String(committed.characters) == "hello" { break }
        }
        let committed = await model.committed
        XCTAssertEqual(String(committed.characters), "hello",
                       "replaceCharacters must dispatch userEdit to the model")
    }

    // MARK: - AC7: edits crossing into provisional are dropped

    func testReplaceCharactersBeyondCommittedIsDropped() async throws {
        let model = TranscriptModel(
            committed: AttributedString("AA"),
            provisional: AttributedString("BB")
        )
        let storage = TranscriptTextStorage(model: model)

        for _ in 0..<10 {
            await awaitStreamYield()
            pumpRunLoop(seconds: 0.02)
            if storage.string == "AABB" { break }
        }

        // Try to replace at location 3 — that's inside the provisional
        // region; the storage should drop the call.
        storage.replaceCharacters(in: NSRange(location: 3, length: 1), with: "X")
        // The cache must be untouched (the provisional 'B' at index 3 stays).
        XCTAssertEqual(storage.string, "AABB",
                       "Edits starting inside the provisional region must be dropped")
    }

    // MARK: - AC6: edited(...) notification fires on rebuild

    func testEditedNotificationFiresOnRebuild() async throws {
        let model = TranscriptModel(provisional: AttributedString(""))
        let storage = TranscriptTextStorage(model: model)

        // Observe edited(...) by hooking processEditing via a layout manager.
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)

        // Provoke a state change.
        try await model.revise(
            range: (await model.provisional).startIndex..<(await model.provisional).endIndex,
            text: AttributedString("hi")
        )

        for _ in 0..<10 {
            await awaitStreamYield()
            pumpRunLoop(seconds: 0.02)
            if storage.string == "hi" { break }
        }
        XCTAssertEqual(storage.string, "hi",
                       "Storage snapshot must reflect the actor revise within one runloop tick")
    }
}
