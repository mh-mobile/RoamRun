import Foundation

/// What one Mac hands another, as a line a person carries, so that a Mac that never shared a
/// network with a device can be introduced to it. Neither holds a key, and neither says where
/// anything is to go: the Mac that reads one finds that out from its own Tailscale.
enum Introduction {
    /// A Mac's offer to pair, as Xcode announces it: what to announce in its place, and the
    /// port it listens on.
    struct Offer: Codable, Equatable {
        var v = 1
        var port: UInt16
        var txt: [String: String]

        static let prefix = "rr-xcode-offer-v1:"
        static let keys: Set<String> = ["identifier", "authTag", "model", "name", "flags", "ver", "minVer"]
    }

    /// A saved device without its UDID or any key: what a bridge announces for it, and the
    /// name Tailscale knows it by.
    struct Device: Codable, Equatable {
        var v = 1
        var name: String
        var peer: String
        var port: UInt16
        var txt: [String: String]

        static let prefix = "rr-device-v1:"
        static let keys: Set<String> = ["identifier", "authTag", "flags", "ver", "minVer"]
    }

    static func line(_ offer: Offer) -> String { Offer.prefix + packed(offer) }
    static func line(_ device: Device) -> String { Device.prefix + packed(device) }

    enum Unreadable: Error, Equatable {
        /// The other kind of line, or a key file's path: named, so the message can say which.
        case another(String)
        case notOne
        case refused(String)
    }

    static func offer(from line: String) -> Result<Offer, Unreadable> {
        let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix(Device.prefix) { return .failure(.another("a saved device (for `roamrun devices add`)")) }
        guard line.hasPrefix(Offer.prefix), let offer: Offer = unpacked(line.dropFirst(Offer.prefix.count)), offer.v == 1 else {
            return .failure(.notOne)
        }
        if let problem = portProblem(offer.port) ?? txtProblem(offer.txt, keys: Offer.keys) { return .failure(.refused(problem)) }
        return .success(offer)
    }

    static func device(from line: String) -> Result<Device, Unreadable> {
        let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix(Offer.prefix) { return .failure(.another("a Mac's offer to pair (for `roamrun pair introduce`)")) }
        guard line.hasPrefix(Device.prefix), let device: Device = unpacked(line.dropFirst(Device.prefix.count)), device.v == 1 else {
            return .failure(.notOne)
        }
        if let problem = portProblem(device.port) ?? txtProblem(device.txt, keys: Device.keys) { return .failure(.refused(problem)) }
        if let problem = [DeviceProfile]().nameProblem(device.name) { return .failure(.refused("its name: \(problem)")) }
        guard device.name.utf8.count <= 64, shows(device.name) else { return .failure(.refused("its name can't be shown as it is")) }
        let peer = device.peer.lowercased()
        guard (1...253).contains(peer.utf8.count), !peer.hasPrefix("-"), !peer.hasPrefix("."),
              peer.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == ".") }) else {
            return .failure(.refused("its Tailscale name isn't one"))
        }
        return .success(device)
    }

    /// Nothing below 1024 is a port either kind of listener takes.
    private static func portProblem(_ port: UInt16) -> String? {
        port >= 1024 ? nil : "port \(port) isn't one a pairing listens on"
    }

    /// Exactly the keys this was built for, each a value of its kind. A record made of these
    /// is announced on a LAN and its name shown on a device: nothing that isn't plainly a
    /// value gets there.
    static func txtProblem(_ txt: [String: String], keys: Set<String>) -> String? {
        let given = Set(txt.keys)
        if given != keys {
            let missing = keys.subtracting(given).sorted(), extra = given.subtracting(keys).sorted()
            return "its announcement isn't the kind this RoamRun knows"
                + (missing.isEmpty ? "" : " (missing: \(missing.joined(separator: ", ")))")
                + (extra.isEmpty ? "" : " (not known: \(extra.count))")
        }
        for (key, value) in txt {
            let ok: Bool
            switch key {
            case "identifier": ok = UUID(uuidString: value) != nil
            case "authTag": ok = (1...32).contains(value.utf8.count) && value.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "+" || $0 == "/") }
            case "model": ok = (1...40).contains(value.utf8.count) && value.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || ",._-".unicodeScalars.contains($0)) }
            case "name": ok = (1...63).contains(value.utf8.count) && shows(value) && !value.contains("=") && !value.contains("\\")
            default: ok = (1...6).contains(value.utf8.count) && value.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
            }
            if !ok { return "its announcement's \(key) isn't one" }
        }
        return nil
    }

    /// Whether text reads on a screen as what it is: no control characters, none that format
    /// or reorder what is around them, and no line breaks.
    static func shows(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy {
            switch $0.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned: return false
            default: return true
            }
        }
    }

    private static func packed<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(value)) ?? Data()
        return data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // ponytail: 4 KB is many times either line; nothing longer is read at all.
    private static func unpacked<T: Decodable>(_ text: Substring) -> T? {
        guard text.utf8.count <= 4096 else { return nil }
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
