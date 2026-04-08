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
            numberOfCharacters: 0
        )

        #expect(context.currentValue.isEmpty)
        #expect(context.selectedRange == NSRange(location: 0, length: 0))
    }

    @Test("matching placeholder remains real content when character count is non-zero")
    func placeholderTextDoesNotOverrideRealContent() {
        let context = TextInsertionService.normalizedAXValueInsertionContext(
            currentValue: "Reply...",
            selectedRange: CFRange(location: 8, length: 0),
            placeholderValue: "Reply...",
            numberOfCharacters: 8
        )

        #expect(context.currentValue == "Reply...")
        #expect(context.selectedRange == NSRange(location: 8, length: 0))
    }

    @Test("missing placeholder leaves content unchanged")
    func missingPlaceholderLeavesContentUnchanged() {
        let context = TextInsertionService.normalizedAXValueInsertionContext(
            currentValue: "hello world",
            selectedRange: CFRange(location: 5, length: 0),
            placeholderValue: nil,
            numberOfCharacters: 11
        )

        #expect(context.currentValue == "hello world")
        #expect(context.selectedRange == NSRange(location: 5, length: 0))
    }
}
