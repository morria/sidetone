import Foundation
import Crypto
import _CryptoExtras
import X509
import SwiftASN1

/// Generates and persists a self-signed P256 server cert.
///
/// First run: creates a fresh P256 keypair, builds a minimal X.509
/// v3 self-signed cert valid for 10 years, stores both in a durable
/// file. Subsequent runs load the same cert — clients pin on first
/// pairing and will see a stable fingerprint across server restarts.
///
/// The private key material is stored on disk (not in Keychain) so the
/// NIOSSL bindings can load it synchronously from a PEM bundle on
/// startup. File permissions are left to the OS — in practice this
/// lives inside Application Support which is user-scoped on macOS.
public struct CertificateManager: Sendable {
    public struct MaterializedCertificate: Sendable {
        public let pemCertificate: String
        public let pemPrivateKey: String
        public let fingerprintSHA256: String
    }

    public let storageDirectory: URL

    public init(storageDirectory: URL) {
        self.storageDirectory = storageDirectory
    }

    /// Load an existing cert or generate a new one. Idempotent.
    public func loadOrGenerate(commonName: String) throws -> MaterializedCertificate {
        let certURL = storageDirectory.appendingPathComponent("sidetone-server.crt.pem")
        let keyURL = storageDirectory.appendingPathComponent("sidetone-server.key.pem")

        try FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )

        if let cert = try? String(contentsOf: certURL, encoding: .utf8),
           let key = try? String(contentsOf: keyURL, encoding: .utf8) {
            let fp = try Self.fingerprint(pemCertificate: cert)
            return MaterializedCertificate(pemCertificate: cert, pemPrivateKey: key, fingerprintSHA256: fp)
        }

        let materialized = try Self.generate(commonName: commonName)
        try materialized.pemCertificate.write(to: certURL, atomically: true, encoding: .utf8)
        try materialized.pemPrivateKey.write(to: keyURL, atomically: true, encoding: .utf8)
        return materialized
    }

    /// Generate a fresh self-signed cert + key. Not persisted.
    public static func generate(commonName: String) throws -> MaterializedCertificate {
        let swiftKey = P256.Signing.PrivateKey()
        let key = Certificate.PrivateKey(swiftKey)

        let subject = try DistinguishedName {
            CommonName(commonName)
        }

        let now = Date()
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: key.publicKey,
            notValidBefore: now.addingTimeInterval(-60),
            notValidAfter: now.addingTimeInterval(10 * 365 * 24 * 3600),
            issuer: subject,
            subject: subject,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(
                    BasicConstraints.notCertificateAuthority
                )
                Critical(
                    KeyUsage(digitalSignature: true, keyCertSign: false)
                )
                SubjectAlternativeNames([.dnsName(commonName), .dnsName("localhost")])
            },
            issuerPrivateKey: key
        )

        let certPEM = try certificate.serializeAsPEM().pemString
        let keyPEM = try swiftKey.pemRepresentation

        var certSerialized = DER.Serializer()
        try certificate.serialize(into: &certSerialized)
        let fp = Self.sha256Hex(Data(certSerialized.serializedBytes))

        return MaterializedCertificate(
            pemCertificate: certPEM,
            pemPrivateKey: keyPEM,
            fingerprintSHA256: fp
        )
    }

    public static func fingerprint(pemCertificate: String) throws -> String {
        let certificate = try Certificate(pemEncoded: pemCertificate)
        var serializer = DER.Serializer()
        try certificate.serialize(into: &serializer)
        return sha256Hex(Data(serializer.serializedBytes))
    }

    private static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
