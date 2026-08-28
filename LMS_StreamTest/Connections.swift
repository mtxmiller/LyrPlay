import Foundation

enum LMSConnections {
    static func buildURLString(useHTTPS: Bool, host: String, port: Int, path: String) -> String {
        let scheme = useHTTPS ? "https" : "http"
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        return "\(scheme)://\(host):\(port)\(normalizedPath)"
    }

    static func handleWebViewChallenge(
        settings: SettingsManager,
        challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard settings.activeServerWebUseHTTPS,
              settings.activeServerAllowSelfSignedCert,
              let credential = serverTrustCredential(expectedHost: settings.activeServerHost, challenge: challenge) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        completionHandler(.useCredential, credential)
    }

    static func serverTrustCredential(expectedHost: String, challenge: URLAuthenticationChallenge) -> URLCredential? {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == expectedHost,
              let trust = challenge.protectionSpace.serverTrust else {
            return nil
        }

        return URLCredential(trust: trust)
    }
}

extension URLSession {
    static func lms(host: String, allowSelfSignedCert: Bool) -> URLSession {
        guard allowSelfSignedCert else {
            return URLSession.shared
        }

        let config = URLSessionConfiguration.default
        let delegate = LMSServerTrustDelegate(expectedHost: host)
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    static var lms: URLSession {
        let settings = SettingsManager.shared
        return lms(host: settings.activeServerHost, allowSelfSignedCert: settings.activeServerAllowSelfSignedCert)
    }
}

private final class LMSServerTrustDelegate: NSObject, URLSessionDelegate {
    private let expectedHost: String

    init(expectedHost: String) {
        self.expectedHost = expectedHost
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let credential = LMSConnections.serverTrustCredential(expectedHost: expectedHost, challenge: challenge) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        completionHandler(.useCredential, credential)
    }
}
