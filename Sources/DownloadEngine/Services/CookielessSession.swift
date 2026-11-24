import Foundation

extension URLSessionConfiguration {
    /// `.default` without the app's own cookie jar or credential store. The
    /// default stores every Set-Cookie in `HTTPCookieStorage.shared` (on disk)
    /// and attaches cached Basic/Digest credentials from `URLCredentialStorage`
    /// — so a cookie or credential from one download could ride along on
    /// another. With this, the only credentials a request carries are the ones
    /// explicitly attached for it.
    static var cookieless: URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCredentialStorage = nil
        #if DEBUG
        if let testProtocolClasses { config.protocolClasses = testProtocolClasses }
        #endif
        return config
    }

    #if DEBUG
    /// Tests put a stub `URLProtocol` in front of the sessions the engine
    /// builds itself; a registered protocol never reaches a custom session.
    nonisolated(unsafe) static var testProtocolClasses: [AnyClass]? {
        didSet { URLSession.resetDebugCookielessSession() }
    }
    #endif
}

extension URLSession {
    /// Replaces `URLSession.shared` for engine traffic.
    static var cookieless: URLSession {
        #if DEBUG
        if URLSessionConfiguration.testProtocolClasses != nil {
            return debugCookielessLock.withLock {
                if let existing = debugCookielessSession { return existing }
                let session = URLSession(
                    configuration: .cookieless,
                    delegate: CrossHostURLSessionDelegate.redirectOnly,
                    delegateQueue: nil
                )
                debugCookielessSession = session
                return session
            }
        }
        #endif
        return sharedCookieless
    }

    private static let sharedCookieless = URLSession(
        configuration: .cookieless,
        delegate: CrossHostURLSessionDelegate.redirectOnly,
        delegateQueue: nil
    )

    #if DEBUG
    private static let debugCookielessLock = NSLock()
    nonisolated(unsafe) private static var debugCookielessSession: URLSession?

    fileprivate static func resetDebugCookielessSession() {
        let old = debugCookielessLock.withLock { () -> URLSession? in
            defer { debugCookielessSession = nil }
            return debugCookielessSession
        }
        old?.finishTasksAndInvalidate()
    }
    #endif
}
