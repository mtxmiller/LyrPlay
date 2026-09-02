import Foundation
import Security
import os.log

enum LMSConnections {
    private static let logger = OSLog(subsystem: "com.lmsstream", category: "Connections")

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
              challenge.protectionSpace.host.caseInsensitiveCompare(expectedHost) == .orderedSame,
              let trust = challenge.protectionSpace.serverTrust else {
            return nil
        }

        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) {
            return URLCredential(trust: trust)
        }

        // Self-signed override: anchor the presented leaf and re-evaluate under a
        // basic X.509 policy, so the certificate must still be well-formed and
        // within its validity window. Hostname matching is deliberately not
        // enforced here — home servers are usually addressed by LAN IP, which
        // self-signed certs rarely carry as a SAN.
        guard let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
            return nil
        }
        SecTrustSetPolicies(trust, SecPolicyCreateBasicX509())
        SecTrustSetAnchorCertificates(trust, [leaf] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        var overrideError: CFError?
        if SecTrustEvaluateWithError(trust, &overrideError) {
            os_log(.info, log: logger, "Accepted self-signed certificate for %{public}s", expectedHost)
            return URLCredential(trust: trust)
        }
        os_log(.error, log: logger, "Rejected certificate for %{public}s: %{public}s",
               expectedHost, String(describing: overrideError ?? error))
        return nil
    }

    // MARK: - Session cache

    private static let sessionLock = NSLock()
    private static var cachedSession: URLSession?
    private static var cachedSessionHost: String?

    /// One live delegate-backed session per host. URLSession strongly retains
    /// its delegate until invalidated, so creating a session per request leaks;
    /// caching also preserves TCP/TLS connection reuse across requests.
    static func session(host: String, allowSelfSignedCert: Bool) -> URLSession {
        guard allowSelfSignedCert else {
            return .shared
        }

        let key = host.lowercased()
        sessionLock.lock()
        defer { sessionLock.unlock() }

        if let session = cachedSession, cachedSessionHost == key {
            return session
        }

        cachedSession?.finishTasksAndInvalidate()
        let session = URLSession(
            configuration: .default,
            delegate: LMSServerTrustDelegate(expectedHost: host),
            delegateQueue: nil
        )
        cachedSession = session
        cachedSessionHost = key
        return session
    }
}

extension URLSession {
    static func lms(host: String, allowSelfSignedCert: Bool) -> URLSession {
        LMSConnections.session(host: host, allowSelfSignedCert: allowSelfSignedCert)
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
