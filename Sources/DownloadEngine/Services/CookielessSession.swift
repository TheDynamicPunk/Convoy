import Foundation

extension URLSessionConfiguration {
    /// `.default` without the app's own cookie jar. The default stores every
    /// Set-Cookie in `HTTPCookieStorage.shared` (on disk) and attaches it to
    /// later requests to that site — so a cookie set during an incognito
    /// download would ride along on a normal-window one. With this, the only
    /// cookies a request carries are the ones the extension captured for it.
    static var cookieless: URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        #if DEBUG
        if let testProtocolClasses { config.protocolClasses = testProtocolClasses }
        #endif
        return config
    }

    #if DEBUG
    /// Tests put a stub `URLProtocol` in front of the sessions the engine
    /// builds itself; a registered protocol never reaches a custom session.
    nonisolated(unsafe) static var testProtocolClasses: [AnyClass]?
    #endif
}

extension URLSession {
    /// Replaces `URLSession.shared` for engine traffic.
    static var cookieless: URLSession {
        #if DEBUG
        // Built once, before any test may have set its stub.
        if URLSessionConfiguration.testProtocolClasses != nil { return URLSession(configuration: .cookieless) }
        #endif
        return sharedCookieless
    }

    private static let sharedCookieless = URLSession(configuration: .cookieless)
}
