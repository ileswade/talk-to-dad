import AppKit
import CryptoKit
import Foundation

/// Keeps Talk to Dad up to date from the project's GitHub releases.
/// Checks at launch, every 6 hours, and when the family app asks ("Update Dad's Mac").
/// Only installs a release whose zip carries a valid signature from the family's update key.
final class Updater: ObservableObject {
    static let repo = "ileswade/talk-to-dad"
    /// Public half of the update-signing key (the private half never leaves Iles's Mac).
    static let publicKey = "d6bbeGaVLxneGMkQbTtT9ZzLbzF4guStE5WovS6Lmxo="

    @Published var status = ""
    var onStatus: ((String) -> Void)?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private var busy = false
    private var timer: Timer?

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { self.check(install: true) }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.check(install: true) }
    }

    /// Looks for a newer release and (if `install`) downloads, verifies and installs it.
    func check(install: Bool) {
        guard !busy else { return }
        busy = true
        report("Checking for updates…")
        Task {
            defer { busy = false }
            do {
                let release = try await latestRelease()
                guard Self.isNewer(release.version, than: Self.currentVersion) else {
                    report("Up to date (version \(Self.currentVersion)).")
                    return
                }
                guard install else { report("Version \(release.version) is available."); return }
                report("Downloading version \(release.version)…")
                let zip = try await download(release.zipURL)
                let signature = try await download(release.sigURL)
                guard try verify(zip: zip, signature: signature) else {
                    report("Update \(release.version) rejected: signature check failed.")
                    return
                }
                report("Installing version \(release.version)…")
                try installUpdate(zip: zip)
            } catch {
                report("Update check failed: \(error.localizedDescription)")
            }
        }
    }

    private func report(_ text: String) {
        DispatchQueue.main.async {
            self.status = text
            self.onStatus?(text)
        }
    }

    // MARK: GitHub

    private struct Release { let version: String; let zipURL: URL; let sigURL: URL }

    private func latestRelease() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]] else { throw Self.fail("No release information.") }
        func asset(_ name: String) -> URL? {
            assets.first { $0["name"] as? String == name }.flatMap { ($0["browser_download_url"] as? String).flatMap(URL.init(string:)) }
        }
        guard let zip = asset("Talk-to-Dad.zip"), let sig = asset("Talk-to-Dad.zip.sig") else {
            throw Self.fail("Release \(tag) has no signed update.")
        }
        return Release(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")), zipURL: zip, sigURL: sig)
    }

    private func download(_ url: URL) async throws -> URL {
        let (temp, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Self.fail("Download failed.") }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        try FileManager.default.moveItem(at: temp, to: dest)
        return dest
    }

    // MARK: Verify and install

    private func verify(zip: URL, signature: URL) throws -> Bool {
        guard let keyData = Data(base64Encoded: Self.publicKey),
              let sigText = try? String(contentsOf: signature, encoding: .utf8),
              let sig = Data(base64Encoded: sigText.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        let digest = SHA256.hash(data: try Data(contentsOf: zip, options: .mappedIfSafe))
        return key.isValidSignature(sig, for: Data(digest))
    }

    private func installUpdate(zip: URL) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("ttd-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
        let newApp = work.appendingPathComponent("Talk to Dad.app")
        guard let bundle = Bundle(url: newApp), bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw Self.fail("The downloaded app isn't Talk to Dad.")
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", newApp.path])

        // Swap the app once this copy has quit, then reopen it.
        let current = Bundle.main.bundleURL
        guard fm.isWritableFile(atPath: current.deletingLastPathComponent().path) else {
            throw Self.fail("Can't write to \(current.deletingLastPathComponent().path).")
        }
        let backup = current.deletingLastPathComponent().appendingPathComponent(".Talk to Dad (previous).app")
        let script = """
            while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.5; done
            rm -rf \(Self.q(backup.path))
            mv \(Self.q(current.path)) \(Self.q(backup.path)) && mv \(Self.q(newApp.path)) \(Self.q(current.path)) || mv \(Self.q(backup.path)) \(Self.q(current.path))
            open \(Self.q(current.path))
            """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "(\(script)) >/dev/null 2>&1 &"]
        try p.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
    }

    private func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Self.fail("\(URL(fileURLWithPath: tool).lastPathComponent) failed.") }
    }

    private static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func fail(_ message: String) -> NSError {
        NSError(domain: "TTDUpdate", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}
