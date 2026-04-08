import Foundation
import Testing
@testable import HanzoCore

@Suite("TextInsertionService")
struct TextInsertionServiceTests {
    @Test("placeholder accessibility value is normalized to empty content")
    func placeholderAccessibilityValueNormalizesToEmptyContent() {
        let context = TextInsertionService.normalizedAXValueInsertionContext(
            currentValue: "Reply...",
            selectedRange: CFRange(location: 8, length: 0),
            placeholderValue: "Reply...",
            numberOfCharacters: 0,
            placeholderSentinels: []
        )

        #expect(context.currentValue.isEmpty)
        #expect(context.selectedRange == NSRange(location: 0, length: 0))
    }

    @Test("matching placeholder is treated as empty even when character count is non-zero")
    func matchingPlaceholderWithCharacterCountIsStillEmpty() {
        let context = TextInsertionService.normalizedAXValueInsertionContext(
            currentValue: "Reply...",
            selectedRange: CFRange(location: 8, length: 0),
            placeholderValue: "Reply...",
            numberOfCharacters: 8,
            placeholderSentinels: []
        )

        #expect(context.currentValue.isEmpty)
        #expect(context.selectedRange == NSRange(location: 0, length: 0))
    }

    @Test("app placeholder sentinel is normalized to empty without AX placeholder metadata")
    func appPlaceholderSentinelNormalizesToEmpty() {
        let context = TextInsertionService.normalizedAXValueInsertionContext(
            currentValue: "Reply…",
            selectedRange: CFRange(location: 6, length: 0),
            placeholderValue: nil,
            numberOfCharacters: 6,
            placeholderSentinels: ["Reply...", "Reply…"]
        )

        #expect(context.currentValue.isEmpty)
        #expect(context.selectedRange == NSRange(location: 0, length: 0))
    }

    @Test("missing placeholder leaves content unchanged")
    func missingPlaceholderLeavesContentUnchanged() {
        let context = TextInsertionService.normalizedAXValueInsertionContext(
            currentValue: "hello world",
            selectedRange: CFRange(location: 5, length: 0),
            placeholderValue: nil,
            numberOfCharacters: 11,
            placeholderSentinels: []
        )

        #expect(context.currentValue == "hello world")
        #expect(context.selectedRange == NSRange(location: 5, length: 0))
    }

    @Test("real content that only starts with reply stays unchanged")
    func realContentThatStartsWithReplyStaysUnchanged() {
        let context = TextInsertionService.normalizedAXValueInsertionContext(
            currentValue: "Reply with details",
            selectedRange: CFRange(location: 18, length: 0),
            placeholderValue: nil,
            numberOfCharacters: 18,
            placeholderSentinels: ["Reply...", "Reply…"]
        )

        #expect(context.currentValue == "Reply with details")
        #expect(context.selectedRange == NSRange(location: 18, length: 0))
    }
}
