import Foundation
import Testing
@testable import SidetoneServer

@Suite("CertificateManager")
struct CertificateManagerTests {
    @Test("generate produces a valid-looking PEM cert + key and a stable fingerprint")
    func generate() throws {
        let m = try CertificateManager.generate(commonName: "sidetone-test")
        #expect(m.pemCertificate.contains("BEGIN CERTIFICATE"))
        #expect(m.pemCertificate.contains("END CERTIFICATE"))
        #expect(m.pemPrivateKey.contains("BEGIN EC PRIVATE KEY")
                || m.pemPrivateKey.contains("BEGIN PRIVATE KEY"))
        #expect(m.fingerprintSHA256.count == 64)
    }

    @Test("fingerprint is deterministic for a given cert PEM")
    func fingerprintStable() throws {
        let m = try CertificateManager.generate(commonName: "sidetone-test")
        let again = try CertificateManager.fingerprint(pemCertificate: m.pemCertificate)
        #expect(m.fingerprintSHA256 == again)
    }

    @Test("loadOrGenerate persists across calls")
    func persistence() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sidetone-cert-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let mgr = CertificateManager(storageDirectory: dir)
        let first = try mgr.loadOrGenerate(commonName: "sidetone-persist")
        let second = try mgr.loadOrGenerate(commonName: "sidetone-persist")
        #expect(first.fingerprintSHA256 == second.fingerprintSHA256)
        #expect(first.pemCertificate == second.pemCertificate)
    }
}
