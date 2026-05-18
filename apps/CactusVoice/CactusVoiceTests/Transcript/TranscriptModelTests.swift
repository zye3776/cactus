import XCTest
import AppKit
@testable import CactusVoice

/// Runtime tests for `TranscriptModel` actor — covers Story 2.2 ACs 4-8:
/// empty-init invariants, commit-grows-prefix, revise-replaces-tail,
/// userEdit-mutates-prefix, illegal-range cases throw, AsyncStream delivers
/// every update in order, concurrent commit + userEdit preserves invariants.
final class TranscriptModelTests: XCTestCase {

    // MARK: - Helpers

    private func makeAttributed(_ raw: String) -> AttributedString {
        AttributedString(raw)
    }

    private func entireProvisional(of model: TranscriptModel) async -> Range<AttributedString.Index> {
        await model.provisional.startIndex..<model.provisional.endIndex
    }

    private func entireCommitted(of model: TranscriptModel) async -> Range<AttributedString.Index> {
        await model.committed.startIndex..<model.committed.endIndex
    }

    // MARK: - AC: empty-init invariants

    func testEmptyInitInvariants() async {
        let model = TranscriptModel()
        let committed = await model.committed
        let provisional = await model.provisional
        XCTAssertEqual(String(committed.characters), "",
                       "committed must start empty")
        XCTAssertEqual(String(provisional.characters), "",
                       "provisional must start empty")
    }

    // MARK: - AC: commit grows the committed prefix

    func testCommitGrowsCommittedPrefix() async throws {
        let model = TranscriptModel(
            committed: AttributedString(""),
            provisional: makeAttributed("hello world")
        )
        let range = await entireProvisional(of: model)
        try await model.commit(range: range, text: makeAttributed("hello world"))

        let committed = await model.committed
        let provisional = await model.provisional
        XCTAssertEqual(String(committed.characters), "hello world",
                       "commit must append the replacement text to committed")
        XCTAssertEqual(String(provisional.characters), "",
                       "commit must remove the committed span from provisional")
    }

    // MARK: - AC: revise replaces the provisional tail

    func testReviseReplacesProvisionalTail() async throws {
        let model = TranscriptModel(provisional: makeAttributed("helo"))
        let range = await entireProvisional(of: model)
        try await model.revise(range: range, text: makeAttributed("hello there"))

        let provisional = await model.provisional
        let committed = await model.committed
        XCTAssertEqual(String(provisional.characters), "hello there",
                       "revise must replace provisional with the new text")
        XCTAssertEqual(String(committed.characters), "",
                       "revise must not touch committed")
    }

    // MARK: - AC: userEdit mutates the committed prefix

    func testUserEditMutatesCommittedPrefix() async throws {
        let model = TranscriptModel(
            committed: makeAttributed("hellp world"),
            provisional: AttributedString("")
        )
        let committed = await model.committed
        // Replace the 'p' (index 4..<5) with 'o'.
        let lo = committed.index(committed.startIndex, offsetByCharacters: 4)
        let hi = committed.index(committed.startIndex, offsetByCharacters: 5)
        try await model.userEdit(range: lo..<hi, text: makeAttributed("o"))

        let after = await model.committed
        XCTAssertEqual(String(after.characters), "hello world",
                       "userEdit must replace the targeted span in committed")
    }

    // MARK: - AC: illegal ranges throw

    func testCommitOnEmptyProvisionalIsOnlyEmptyRange() async throws {
        let model = TranscriptModel(provisional: makeAttributed("abc"))
        // Build a range using the committed AttributedString — passing it
        // to commit must throw because it's not from `provisional`.
        let committed = await model.committed
        let badRange = committed.startIndex..<committed.endIndex
        do {
            try await model.commit(range: badRange, text: makeAttributed("x"))
            XCTFail("commit with foreign range must throw")
        } catch let error as TranscriptModelError {
            XCTAssertEqual(error, .rangeNotInProvisional)
        } catch {
            XCTFail("expected TranscriptModelError.rangeNotInProvisional, got \(error)")
        }
    }

    func testUserEditWithForeignRangeThrows() async throws {
        let model = TranscriptModel(
            committed: makeAttributed("abc"),
            provisional: makeAttributed("xyz")
        )
        // Use a provisional range against userEdit.
        let provisional = await model.provisional
        let badRange = provisional.startIndex..<provisional.endIndex
        do {
            try await model.userEdit(range: badRange, text: makeAttributed("Q"))
            XCTFail("userEdit with foreign range must throw")
        } catch let error as TranscriptModelError {
            XCTAssertEqual(error, .rangeNotInCommitted)
        } catch {
            XCTFail("expected TranscriptModelError.rangeNotInCommitted, got \(error)")
        }
    }

    func testReviseWithForeignRangeThrows() async throws {
        let model = TranscriptModel(
            committed: makeAttributed("abc"),
            provisional: makeAttributed("xyz")
        )
        let committed = await model.committed
        let badRange = committed.startIndex..<committed.endIndex
        do {
            try await model.revise(range: badRange, text: makeAttributed("Q"))
            XCTFail("revise with foreign range must throw")
        } catch let error as TranscriptModelError {
            XCTAssertEqual(error, .rangeNotInProvisional)
        } catch {
            XCTFail("expected TranscriptModelError.rangeNotInProvisional, got \(error)")
        }
    }

    // MARK: - AC: AsyncStream delivers every update in order

    func testUpdatesStreamDeliversInOrder() async throws {
        let model = TranscriptModel(provisional: makeAttributed("hi"))
        let updates = await model.updates

        // Collect three updates: revise, commit, userEdit.
        let collected: Task<[String], Never> = Task {
            var labels: [String] = []
            for await update in updates {
                switch update {
                case .commit: labels.append("commit")
                case .revise: labels.append("revise")
                case .userEdit: labels.append("userEdit")
                }
                if labels.count == 3 { break }
            }
            return labels
        }

        let provisionalRange = await entireProvisional(of: model)
        try await model.revise(range: provisionalRange, text: makeAttributed("hello"))

        let newProvisional = await model.provisional
        let commitRange = newProvisional.startIndex..<newProvisional.endIndex
        try await model.commit(range: commitRange, text: makeAttributed("hello"))

        let committedNow = await model.committed
        let editRange = committedNow.startIndex..<committedNow.index(committedNow.startIndex, offsetByCharacters: 1)
        try await model.userEdit(range: editRange, text: makeAttributed("H"))

        let labels = await collected.value
        XCTAssertEqual(labels, ["revise", "commit", "userEdit"],
                       "updates stream must deliver every state change in order")
    }

    // MARK: - AC: concurrent commit + userEdit preserves invariants

    func testConcurrentCommitAndUserEditPreservesInvariants() async throws {
        let model = TranscriptModel(
            committed: makeAttributed("AAA"),
            provisional: makeAttributed("BBB")
        )

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                let provisional = await model.provisional
                let range = provisional.startIndex..<provisional.endIndex
                try? await model.commit(range: range, text: AttributedString("BBB"))
            }
            group.addTask {
                let committed = await model.committed
                // Append 'X' by replacing the empty range at endIndex.
                let end = committed.endIndex
                try? await model.userEdit(range: end..<end, text: AttributedString("X"))
            }
        }

        let committed = await model.committed
        let provisional = await model.provisional

        // committed must contain the original 'AAA' as a prefix, plus either
        // 'X' (if userEdit ran first) or 'BBB' first then 'X' or the
        // committed 'BBB' span — the invariant is that committed contains
        // every committed character exactly once, and provisional ends empty
        // after the commit.
        XCTAssertEqual(String(provisional.characters), "",
                       "provisional must be empty after commit completes")
        XCTAssertTrue(String(committed.characters).contains("AAA"),
                      "committed prefix must retain its original content")
        XCTAssertTrue(String(committed.characters).contains("BBB"),
                      "committed must include the committed span")
        XCTAssertTrue(String(committed.characters).contains("X"),
                      "committed must include the user edit")
        XCTAssertEqual(String(committed.characters).count, 7,
                       "committed must have exactly 3 (AAA) + 3 (BBB) + 1 (X) characters")
    }
}
