import Network

enum DirectTCP {
    static func parameters(keepalive: Bool = false) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        // Nagle plus delayed ACK adds a round trip to lldb's small requests.
        tcp.noDelay = true
        if keepalive {
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 10
            tcp.keepaliveInterval = 5
            tcp.keepaliveCount = 3 // a sleeping peer never sends FIN
        }
        let parameters = NWParameters(tls: nil, tcp: tcp)
        // RemotePairing and tunnel bytes must reach the peer, not an HTTP/SOCKS proxy.
        parameters.preferNoProxies = true
        return parameters
    }
}
