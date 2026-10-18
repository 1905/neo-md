import CryptoKit
import Foundation
import Testing
@testable import MDCore

@Test func updateVersionCompare() {
    #expect(UpdateVersion.isNewer("0.3.10", than: "0.3.9"))
    #expect(UpdateVersion.compare("1.0", "1.0.0") == .orderedSame)
    #expect(UpdateVersion.compare("0.2.1", "0.3.0") == .orderedAscending)
    #expect(!UpdateVersion.isNewer("0.3.0", than: "0.3.0"))
    #expect(UpdateVersion.isNewer("1", than: "0.9.9"))
}

private let sampleJSON = """
{"version":"0.3.1","build":"5","url":"https://github.com/1905/neo-md/releases/download/v0.3.1/neo-md-0.3.1.zip",
 "size":3,"sha256":"aa","signature":"bb","minimumSystemVersion":"14.0"}
"""

@Test func updateFeedDecodes() throws {
    let feed = try UpdateFeed.decode(Data(sampleJSON.utf8))
    #expect(feed.version == "0.3.1")
    #expect(feed.url.lastPathComponent == "neo-md-0.3.1.zip")
    #expect(feed.minimumSystemVersion == "14.0")
}

@Test func updateFeedWithoutSignatureFails() {
    let json = sampleJSON.replacingOccurrences(of: #","signature":"bb""#, with: "")
    #expect(throws: (any Error).self) { try UpdateFeed.decode(Data(json.utf8)) }
}

/// A feed for `zip` signed with `key`.
private func signedFeed(_ zip: Data, key: Curve25519.Signing.PrivateKey) throws -> UpdateFeed {
    let digest = SHA256.hash(data: zip).map { String(format: "%02x", $0) }.joined()
    let sig = try key.signature(for: zip).base64EncodedString()
    return UpdateFeed(version: "0.3.1", build: "5", url: URL(string: "https://example.com/u.zip")!,
                      size: zip.count, sha256: digest, signature: sig, minimumSystemVersion: "14.0")
}

@Test func updateFeedVerifyAcceptsSignedZip() throws {
    let key = Curve25519.Signing.PrivateKey()
    let zip = Data("zip bytes".utf8)
    let pub = key.publicKey.rawRepresentation.base64EncodedString()
    try signedFeed(zip, key: key).verify(zip: zip, publicKey: pub)
}

@Test func updateFeedVerifyRejects() throws {
    let key = Curve25519.Signing.PrivateKey()
    let zip = Data("zip bytes".utf8)
    let pub = key.publicKey.rawRepresentation.base64EncodedString()
    let feed = try signedFeed(zip, key: key)

    // One changed byte, same size: checksum fails first.
    var changed = zip
    changed[0] ^= 1
    #expect(throws: UpdateFeed.VerifyError.checksum) { try feed.verify(zip: changed, publicKey: pub) }

    #expect(throws: UpdateFeed.VerifyError.size) { try feed.verify(zip: zip + Data([0]), publicKey: pub) }

    let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
    #expect(throws: UpdateFeed.VerifyError.signature) { try feed.verify(zip: zip, publicKey: other) }

    // A matching checksum does not help a forged signature.
    var forged = feed
    forged.signature = try Curve25519.Signing.PrivateKey().signature(for: zip).base64EncodedString()
    #expect(throws: UpdateFeed.VerifyError.signature) { try forged.verify(zip: zip, publicKey: pub) }

    #expect(throws: UpdateFeed.VerifyError.badKey) { try feed.verify(zip: zip, publicKey: "nope") }
}
