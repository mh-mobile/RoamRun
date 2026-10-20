import Foundation

/// A pairing made for another Mac, with the device it is for: what `roamrun key create`
/// writes and `key import` takes. The file is the key: whoever has it and reaches the device
/// can see and operate it.
struct SharedPairing: Codable, Equatable {
    var roamrunPairing = 1
    var device: DeviceProfile
    /// The pairing itself, a property list's text.
    var pairing: String

    static func read(_ data: Data) -> SharedPairing? {
        guard let read = try? JSONDecoder().decode(SharedPairing.self, from: data), read.roamrunPairing == 1,
              !read.pairing.isEmpty, let udid = read.device.udid, DeviceControlWire.plausible(udid: udid),
              isAddress(read.device.providerIP),
              // What a bridge would announce it as: only what RoamRun itself saves.
              read.device.serviceType == "_remotepairing._tcp", ["local", "local."].contains(read.device.domain) else { return nil }
        return read
    }
}

/// An address in numbers: nothing is looked up, and nothing else is connected to.
private func isAddress(_ text: String) -> Bool {
    var v4 = in_addr(), v6 = in6_addr()
    return inet_pton(AF_INET, text, &v4) == 1 || inet_pton(AF_INET6, text, &v6) == 1
}
