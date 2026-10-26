import Combine
import Foundation

/// Keeps a WebSocket open to the TTD relay so the family app can reach Dad's Mac from anywhere.
/// Reconnects by itself. The relay key lives in the macOS Keychain, never in settings files.
public final class RelayClient: ObservableObject {
    public init() {}
    @Published public var connected = false
    @Published public var status = "Not set up"

    @Published public var url: String = UserDefaults.standard.string(forKey: "relayURL") ?? "" {
        didSet { UserDefaults.standard.set(url, forKey: "relayURL") }
    }
    public var hasKey: Bool { Keychain.read("relayKey") != nil }

    public var role = "dad"
    public var name = ""
    public var onMessage: (([String: Any]) -> Void)?
    public var onConnect: (() -> Void)?

    private var task: URLSessionWebSocketTask?
    private var retry: Double = 2
    private var pingTimer: Timer?
    private var stopped = true
    private var outbox: [String] = []       // held while (re)connecting, sent once connected

    public func setKey(_ key: String) {
        Keychain.write("relayKey", key.trimmingCharacters(in: .whitespacesAndNewlines))
        objectWillChange.send()
        restart()
    }

    public func start() {
        stopped = false
        connect()
    }

    public func restart() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        start()
    }

    private func connect() {
        guard !stopped, task == nil else { return }
        guard var parts = URLComponents(string: url), parts.host != nil, let key = Keychain.read("relayKey") else {
            status = "Not set up"
            return
        }
        parts.path = "/ws"
        if parts.scheme == "https" { parts.scheme = "wss" } else if parts.scheme == "http" { parts.scheme = "ws" }
        parts.queryItems = [URLQueryItem(name: "role", value: role)] + (name.isEmpty ? [] : [URLQueryItem(name: "name", value: name)])
        guard let wsURL = parts.url else { return }
        var request = URLRequest(url: wsURL)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let t = URLSession.shared.webSocketTask(with: request)
        t.maximumMessageSize = 16 * 1024 * 1024
        task = t
        status = "Connecting…"
        t.resume()
        receive(on: t)
        // The first successful receive marks us connected; ping keeps the connection alive.
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self, weak t] _ in
            t?.sendPing { error in if error != nil { self?.dropped(t) } }
        }
        t.sendPing { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.task === t else { return }
                if error == nil {
                    self.markConnected(t)
                } else {
                    self.dropped(t)
                }
            }
        }
    }

    private func receive(on t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.task === t else { return }
                switch result {
                case .success(let message):
                    self.markConnected(t)
                    if case .string(let text) = message,
                       let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                        self.onMessage?(obj)
                    }
                    self.receive(on: t)
                case .failure:
                    self.dropped(t)
                }
            }
        }
    }

    private func markConnected(_ t: URLSessionWebSocketTask) {
        guard task === t, !connected else { return }
        connected = true
        status = "Connected"
        retry = 2
        let held = outbox
        outbox.removeAll()
        for text in held { t.send(.string(text)) { _ in } }
        onConnect?()
    }

    private func dropped(_ t: URLSessionWebSocketTask?) {
        DispatchQueue.main.async {
            guard let t, self.task === t else { return }
            self.task = nil
            self.connected = false
            self.status = "Offline — retrying in \(Int(self.retry)) s"
            let wait = self.retry
            self.retry = min(60, self.retry * 2)
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { self.connect() }
        }
    }

    public func send(_ obj: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else {
            NSLog("TTD relay: couldn't encode %@", obj["type"] as? String ?? "?")
            return
        }
        guard let task, connected else {
            // Keep chat lines and replies until the connection is back (presence can be skipped).
            if obj["type"] as? String != "presence" { outbox = Array((outbox + [text]).suffix(50)) }
            return
        }
        task.send(.string(text)) { error in
            if let error { NSLog("TTD relay: send failed: %@", error.localizedDescription) }
        }
    }
}

/// Stores the relay key in a private file (mode 600) in the app's Application Support folder.
/// Not the Keychain: for a self-signed app, every update would make macOS show Dad a password prompt.
public enum Keychain {
    private static var folder: URL {
        let name = Bundle.main.bundleIdentifier ?? "com.ris.talktodad"
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name, isDirectory: true)
    }

    public static func read(_ account: String) -> String? {
        guard let s = try? String(contentsOf: folder.appendingPathComponent(account), encoding: .utf8) else { return nil }
        let v = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    public static func write(_ account: String, _ value: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent(account)
        guard !value.isEmpty else { try? fm.removeItem(at: file); return }
        fm.createFile(atPath: file.path, contents: Data(value.utf8), attributes: [.posixPermissions: 0o600])
    }
}
