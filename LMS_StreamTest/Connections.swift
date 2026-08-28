import Foundation

enum LMSConnections {
    static func buildURLString(useHTTPS: Bool, host: String, port: Int, path: String) -> String {
        let scheme = useHTTPS ? "https" : "http"
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        return "\(scheme)://\(host):\(port)\(normalizedPath)"
    }
}
