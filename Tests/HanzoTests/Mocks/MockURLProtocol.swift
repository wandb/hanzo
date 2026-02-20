import Foundation

final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            // Read body from stream if httpBody is nil (URLSession moves body to stream)
            var requestCopy = request
            if requestCopy.httpBody == nil, let stream = requestCopy.httpBodyStream {
                stream.open()
                var bodyData = Data()
                let bufferSize = 4096
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
                defer {
                    buffer.deallocate()
                    stream.close()
                }
                while stream.hasBytesAvailable {
                    let bytesRead = stream.read(buffer, maxLength: bufferSize)
                    if bytesRead > 0 {
                        bodyData.append(buffer, count: bytesRead)
                    } else {
                        break
                    }
                }
                requestCopy.httpBody = bodyData
            }

            let (response, data) = try handler(requestCopy)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
