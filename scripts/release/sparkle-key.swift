// Sparkle EdDSA (Ed25519) key tool, without the login Keychain.
//
//   swift sparkle-key.swift generate <private-key-file>   writes a new key (refuses to overwrite),
//                                                          mode 600, and prints the public key
//   swift sparkle-key.swift public <private-key-file>     prints the public key of an existing file
//
// The file holds the base64 of the 32-byte Ed25519 seed: the format `generate_keys -x` exports
// and `sign_update --ed-key-file` reads. The public key is base64 of the 32-byte public key, the
// value of Info.plist's SUPublicEDKey. Sparkle's own generate_keys stores the key in the login
// Keychain, which an ad-hoc signed sign_update then can't read without a prompt
// (docs/spikes/m0c-platform.md, experiment 3), so Lectern never uses it.
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("sparkle-key: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments.dropFirst()
guard arguments.count == 2, let mode = arguments.first, let path = arguments.last else {
    fail("usage: sparkle-key.swift generate|public <private-key-file>")
}
let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)

switch mode {
case "generate":
    if FileManager.default.fileExists(atPath: url.path) {
        fail("\(url.path) already exists; refusing to replace a signing key (existing installs trust it)")
    }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
    let key = Curve25519.Signing.PrivateKey()
    let contents = Data(key.rawRepresentation.base64EncodedString().utf8)
    // Created with mode 600 from the start, never readable by others even briefly.
    guard FileManager.default.createFile(atPath: url.path, contents: contents, attributes: [.posixPermissions: 0o600]) else {
        fail("could not write \(url.path)")
    }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "public":
    guard let text = try? String(contentsOf: url, encoding: .utf8),
          let seed = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    else { fail("\(url.path) is not a base64 Ed25519 seed") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
default:
    fail("unknown mode \(mode)")
}
