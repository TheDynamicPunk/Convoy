import Foundation

/// A fake HTTP host for helper tests: no network, no server.
///
/// Used three ways. Set `body` (and `statusCode`) and every request gets it as
/// a streamed download, which is how `ProgressDownload` and the helper
/// installer are tested. Set `failure` and every request fails. Or set
/// `route` to decide each reply from what was asked (a reply can itself be a
/// failure), and read `received` afterwards to see what was sent, which is
/// how the torrent engine is tested.
///
/// State is static because a `URLProtocol` is instantiated by the system, so
/// every test that touches it starts with `reset()`. Tests run one at a time,
/// but requests are served on the system's threads, so all of it is read and
/// written under one lock. A `route` closure can be called from several
/// requests at once; one that keeps state of its own has to guard it.
final class StubHelperProtocol: URLProtocol {

    struct Reply {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        /// When set, the request fails with this instead of getting a response.
        var failure: URLError?
    }

    /// What a request looked like when it arrived.
    struct Received {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data

        var path: String { url.path }
        func query(_ name: String) -> String? {
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
        }
    }

    private struct State {
        var body = Data()
        var failure: URLError?
        var statusCode = 200
        var route: ((Received) -> Reply)?
        var log: [Received] = []
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var state = State()

    private static func read<T>(_ value: (State) -> T) -> T { lock.withLock { value(state) } }
    private static func write(_ change: (inout State) -> Void) { lock.withLock { change(&state) } }

    static var body: Data {
        get { read(\.body) }
        set { write { $0.body = newValue } }
    }

    static var failure: URLError? {
        get { read(\.failure) }
        set { write { $0.failure = newValue } }
    }

    static var statusCode: Int {
        get { read(\.statusCode) }
        set { write { $0.statusCode = newValue } }
    }

    /// When set, decides every reply, and `body` and `statusCode` are ignored.
    static var route: ((Received) -> Reply)? {
        get { read(\.route) }
        set { write { $0.route = newValue } }
    }

    /// Every request since the last `reset()`, oldest first.
    static var received: [Received] { read(\.log) }

    static func reset() {
        write { $0 = State() }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let received = Received(
            method: request.httpMethod ?? "GET",
            url: request.url!,
            headers: request.allHTTPHeaderFields ?? [:],
            body: Self.bodyData(of: request)
        )
        let (failure, route, body, statusCode) = Self.lock.withLock { () -> (URLError?, ((Received) -> Reply)?, Data, Int) in
            Self.state.log.append(received)
            return (Self.state.failure, Self.state.route, Self.state.body, Self.state.statusCode)
        }

        if let failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let reply = route?(received) ?? Reply(status: statusCode, body: body)
        if let failure = reply.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        var headers = reply.headers
        headers["Content-Length"] = "\(reply.body.count)"
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        var offset = 0
        while offset < reply.body.count {
            let end = min(offset + 64 << 10, reply.body.count)
            client?.urlProtocol(self, didLoad: reply.body.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// A request body arrives as a stream, not as `httpBody`.
    private static func bodyData(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
