import Foundation
import Network
import Testing
@testable import RoamRun

extension TimingSensitive {
    @Test func peerTCPDoesNotReachAnHTTPProxy() async throws {
        guard #available(macOS 14, *) else { return }
        let proxy = try EchoServer(silent: true)
        let port = await proxy.start()
        defer { proxy.stop() }
        let context = NWParameters.PrivacyContext(description: "RoamRun isolated test proxy")
        var configuration = ProxyConfiguration(httpCONNECTProxy: .hostPort(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!
        ))
        configuration.allowFailover = false
        context.proxyConfigurations = [configuration]

        func attempt(_ parameters: NWParameters) async {
            parameters.setPrivacyContext(context)
            // TEST-NET: no real device. Only the deliberately configured proxy can accept this.
            let connection = NWConnection(host: "198.51.100.1", port: 49152, using: parameters)
            connection.start(queue: .global())
            try? await Task.sleep(for: .milliseconds(300))
            connection.cancel()
        }

        await attempt(.tcp)
        #expect(try await eventually {
            proxy.accepted > 0
        }, "control connection did not exercise the proxy")
        let before = proxy.accepted
        await attempt(DirectTCP.parameters())
        await attempt(DirectTCP.parameters(keepalive: true))
        #expect(proxy.accepted == before, "peer connections must bypass the HTTP proxy")
    }
}
