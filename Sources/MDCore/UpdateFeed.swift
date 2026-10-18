import CryptoKit
import Foundation

/// `latest.json` of a GitHub release: the newest version and its signed update zip.
public struct UpdateFeed: Codable, Equatable, Sendable {
    public var version: String
    public var build: String
    public var url: URL
    public var size: Int
    /// Lowercase hex SHA-256 of the zip.
    public var sha256: String
    /// Base64 Ed25519 signature of the zip bytes.
    public var signature: String
    public var minimumSystemVersion: String

    public init(version: String, build: String, url: URL, size: Int, sha256: String,
                signature: String, minimumSystemVersion: String) {
        self.version = version
        self.build = build
        self.url = url
        self.size = size
        self.sha256 = sha256
        self.signature = signature
        self.minimumSystemVersion = minimumSystemVersion
    }

    public static func decode(_ data: Data) throws -> UpdateFeed {
        try JSONDecoder().decode(UpdateFeed.self, from: data)
    }

    public enum VerifyError: Error, Equatable, CustomStringConvertible {
        case size, checksum, badKey, signature

        public var description: String {
            switch self {
            case .size: "download size does not match"
            case .checksum: "checksum does not match"
            case .badKey: "update key is missing or invalid"
            case .signature: "signature does not match"
            }
        }
    }

    /// Checks the zip bytes against `size`, `sha256` and the Ed25519 `signature`.
    /// `publicKey` is the base64 raw 32-byte key from Info.plist.
    public func verify(zip: Data, publicKey: String) throws {
        guard zip.count == size else { throw VerifyError.size }
        let digest = SHA256.hash(data: zip).map { String(format: "%02x", $0) }.joined()
        guard digest == sha256.lowercased() else { throw VerifyError.checksum }
        guard let keyData = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            throw VerifyError.badKey
        }
        guard let sig = Data(base64Encoded: signature), key.isValidSignature(sig, for: zip) else {
            throw VerifyError.signature
        }
    }
}

/// Dot-separated integer versions. Missing parts count as 0: "1.0" == "1.0.0", "0.3.10" > "0.3.9".
public enum UpdateVersion {
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }

    private static func parts(_ v: String) -> [Int] {
        v.split(separator: ".").map { Int($0) ?? 0 }
    }
}
