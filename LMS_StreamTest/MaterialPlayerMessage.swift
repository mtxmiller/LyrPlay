import Foundation

/// Parsed form of Material's native player-change message (GH#75).
///
/// Material, loaded with `?nativePlayer=3`, posts to the `mskNative`
/// WKScriptMessageHandler on every player switch (lms-material store.js
/// `storeCurrentPlayer` → utils.js `emitNative`):
///
///     MATERIAL-PLAYER
///     ID aa:bb:cc:dd:ee:ff
///     NAME Kitchen
///     IP 192.168.1.50:34657
///
/// NAME/IP are optional defensively; ID is required.
struct MaterialPlayerMessage: Equatable {
    let id: String
    let name: String?
    let ip: String?

    static func parse(_ raw: String) -> MaterialPlayerMessage? {
        let lines = raw.components(separatedBy: "\n")
        guard lines.first == "MATERIAL-PLAYER" else { return nil }

        var id: String?
        var name: String?
        var ip: String?
        for line in lines.dropFirst() {
            if line.hasPrefix("ID ") {
                id = String(line.dropFirst(3))
            } else if line.hasPrefix("NAME ") {
                name = String(line.dropFirst(5))
            } else if line.hasPrefix("IP ") {
                ip = String(line.dropFirst(3))
            }
        }

        guard let id = id, !id.isEmpty else { return nil }
        return MaterialPlayerMessage(id: id, name: name, ip: ip)
    }
}

/// Material's report of its own (cometd) link to LMS, posted to the same
/// `mskNative` handler when loaded with `?nativeConnectionStatus=w`
/// (lms-material server.js, on every `networkStatus` change). The header is
/// Material's spelling:
///
///     MATERIAL-CONNETIONSTATUS
///     CONNECTED true
///
/// `connected` false is what puts the red icon in Material's toolbar (bd toz7).
struct MaterialConnectionMessage: Equatable {
    let connected: Bool

    static func parse(_ raw: String) -> MaterialConnectionMessage? {
        let lines = raw.components(separatedBy: "\n")
        guard lines.first == "MATERIAL-CONNETIONSTATUS" else { return nil }
        for line in lines.dropFirst() where line.hasPrefix("CONNECTED ") {
            switch line.dropFirst(10).trimmingCharacters(in: .whitespaces) {
            case "true": return MaterialConnectionMessage(connected: true)
            case "false": return MaterialConnectionMessage(connected: false)
            default: return nil
            }
        }
        return nil
    }
}
