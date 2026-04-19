import Foundation
import Testing
@testable import SidetoneCore
import SidetoneTestSupport

extension IntegrationTests {
    @Suite("Bonjour advertise + browse")
    struct BonjourSuite {
        @Test("Browser discovers an advertiser within a few seconds")
        func discover() async throws {
            // Use a unique service type per test run so we don't pick up
            // someone else's Sidetone server on the developer's network.
            let uniqueType = "_sidetone-test-\(UUID().uuidString.prefix(6))._tcp"

            let advertiser = BonjourAdvertiser(configuration: .init(
                serviceType: String(uniqueType),
                serviceName: "sidetone-test-host",
                port: 12345,
                txtRecord: ["fingerprint": "abc123"]
            ))
            try advertiser.start()

            let browser = BonjourBrowser(serviceType: String(uniqueType))
            browser.start()

            // Drain updates until we find our own advertisement or give
            // up after ~4s. mDNS propagation on loopback can take a
            // surprising amount of time on busy CI machines.
            var foundMatch: BonjourBrowser.DiscoveredServer?
            let deadline = Date().addingTimeInterval(4)
            var iter = browser.servers.makeAsyncIterator()
            while foundMatch == nil, Date() < deadline {
                if let list = await iter.next() {
                    foundMatch = list.first { $0.name == "sidetone-test-host" }
                }
            }

            browser.stop()
            advertiser.stop()

            #expect(foundMatch?.name == "sidetone-test-host")
            #expect(foundMatch?.metadata["port"] == "12345")
            #expect(foundMatch?.metadata["fingerprint"] == "abc123")
        }
    }
}
