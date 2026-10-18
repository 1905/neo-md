// Sign an update zip with the neo-md Ed25519 update key. Prints the base64 signature.
// Usage: NEOMD_UPDATE_KEY=<base64 32-byte seed> swift scripts/sign-update.swift <file>
//   or:  NEOMD_UPDATE_KEY_FILE=<path> swift scripts/sign-update.swift <file>
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("sign-update: \(message)\n".utf8))
    exit(1)
}

let env = ProcessInfo.processInfo.environment
let args = CommandLine.arguments
guard args.count == 2 else { fail("usage: sign-update.swift <file>") }

var seedText = env["NEOMD_UPDATE_KEY"] ?? ""
if seedText.isEmpty, let path = env["NEOMD_UPDATE_KEY_FILE"] {
    seedText = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}
guard let seed = Data(base64Encoded: seedText.trimmingCharacters(in: .whitespacesAndNewlines)),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
    fail("set NEOMD_UPDATE_KEY or NEOMD_UPDATE_KEY_FILE to the base64 32-byte key")
}
guard let data = FileManager.default.contents(atPath: args[1]) else { fail("cannot read \(args[1])") }

// Refuse to sign with a key that does not match the public key in Info.plist.
let plistURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../Resources/Info.plist")
if let plist = NSDictionary(contentsOf: plistURL),
   let expected = plist["NeoMDUpdatePublicKey"] as? String,
   expected != key.publicKey.rawRepresentation.base64EncodedString() {
    fail("the key does not match NeoMDUpdatePublicKey in Resources/Info.plist")
}

guard let signature = try? key.signature(for: data) else { fail("signing failed") }
print(signature.base64EncodedString())
