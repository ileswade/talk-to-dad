// Signs an update zip with the private update key: swift tools/sign-update.swift <zip> > <zip>.sig
import CryptoKit
import Foundation
let keyPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ttd-setup/update-signing.key")
guard CommandLine.arguments.count == 2,
      let keyText = try? String(contentsOf: keyPath, encoding: .utf8),
      let raw = Data(base64Encoded: keyText.trimmingCharacters(in: .whitespacesAndNewlines)),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw),
      let zip = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]), options: .mappedIfSafe)
else { FileHandle.standardError.write(Data("usage: sign-update.swift <zip> (needs ~/.ttd-setup/update-signing.key)\n".utf8)); exit(1) }
let sig = try key.signature(for: Data(SHA256.hash(data: zip)))
print(sig.base64EncodedString())
