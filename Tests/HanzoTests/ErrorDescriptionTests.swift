import Testing
import Foundation
@testable import HanzoCore

@Suite("ASRError descriptions")
struct ASRErrorTests {

    @Test("serverError includes status code")
    func serverErrorIncludesCode() {
        let error = ASRError.serverError(statusCode: 500, detail: nil)
        #expect(error.errorDescription?.contains("500") == true)
    }

    @Test("serverError includes detail when present")
    func serverErrorIncludesDetail() {
        let error = ASRError.serverError(statusCode: 503, detail: "Service Unavailable")
        #expect(error.errorDescription?.contains("Service Unavailable") == true)
    }

    @Test("authenticationFailed has non-empty description")
    func authFailed() {
        #expect(ASRError.authenticationFailed.errorDescription?.isEmpty == false)
    }

    @Test("sessionNotFound has non-empty description")
    func sessionNotFound() {
        #expect(ASRError.sessionNotFound.errorDescription?.isEmpty == false)
    }

    @Test("networkError includes underlying description")
    func networkError() {
        struct FakeError: LocalizedError {
            var errorDescription: String? { "connection timeout" }
        }
        let error = ASRError.networkError(underlying: FakeError())
        #expect(error.errorDescription?.contains("connection timeout") == true)
    }

    @Test("invalidURL has non-empty description")
    func invalidURL() {
        #expect(ASRError.invalidURL.errorDescription?.isEmpty == false)
    }
}

@Suite("AudioCaptureError descriptions")
struct AudioCaptureErrorTests {

    @Test("converterCreationFailed has non-empty description")
    func converterFailed() {
        #expect(AudioCaptureError.converterCreationFailed.errorDescription?.isEmpty == false)
    }
}
