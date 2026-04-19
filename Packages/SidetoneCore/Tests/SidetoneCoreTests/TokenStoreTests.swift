import Foundation
import Testing
@testable import SidetoneCore

@Suite("TokenStore — in-memory implementation")
struct InMemoryTokenStoreTests {
    @Test("save, read back, delete")
    func crud() throws {
        let store = InMemoryTokenStore()
        let cred = ServerCredential(
            serverName: "Home Mac",
            token: "abc123",
            certificateFingerprint: "fp",
            pairedAt: Date(timeIntervalSince1970: 1)
        )
        try store.save(cred)

        let fetched = try store.credential(for: "Home Mac")
        #expect(fetched == cred)

        try store.delete(serverName: "Home Mac")
        #expect(try store.credential(for: "Home Mac") == nil)
    }

    @Test("save is an upsert by serverName")
    func upsert() throws {
        let store = InMemoryTokenStore()
        try store.save(ServerCredential(serverName: "Mac", token: "t1", certificateFingerprint: "fp"))
        try store.save(ServerCredential(serverName: "Mac", token: "t2", certificateFingerprint: "fp"))
        #expect(try store.credential(for: "Mac")?.token == "t2")
    }
}
