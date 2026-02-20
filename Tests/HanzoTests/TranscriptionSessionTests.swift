import Testing
import Foundation
@testable import HanzoCore

@Suite("TranscriptionSession")
struct TranscriptionSessionTests {

    @Test("durationSeconds returns nil when startTime is nil")
    func durationNilWhenNoStart() {
        let session = TranscriptionSession()
        session.endTime = Date()
        #expect(session.durationSeconds == nil)
    }

    @Test("durationSeconds returns nil when endTime is nil")
    func durationNilWhenNoEnd() {
        let session = TranscriptionSession()
        session.startTime = Date()
        #expect(session.durationSeconds == nil)
    }

    @Test("durationSeconds returns correct interval")
    func durationCorrect() throws {
        let session = TranscriptionSession()
        let start = Date()
        session.startTime = start
        session.endTime = start.addingTimeInterval(3.5)
        let duration = try #require(session.durationSeconds)
        #expect(duration == 3.5)
    }

    @Test("durationSeconds is zero when start equals end")
    func durationZero() throws {
        let session = TranscriptionSession()
        let now = Date()
        session.startTime = now
        session.endTime = now
        let duration = try #require(session.durationSeconds)
        #expect(duration == 0)
    }
}
