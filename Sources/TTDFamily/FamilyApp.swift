import AppKit
import AVFoundation
import SwiftUI
import TTDShared

/// TTD Family: chat with Dad's Mac from anywhere, hear his recorded answers,
/// see whether he's at the computer, and take a screenshot or camera photo.
@main
struct TTDFamilyApp: App {
    @StateObject private var model = FamilyModel()

    var body: some Scene {
        Window("Talk to Dad — Family", id: "family") {
            FamilyView().environmentObject(model).frame(minWidth: 620, minHeight: 600)
        }
        .defaultSize(width: 900, height: 780)
    }
}

final class FamilyModel: ObservableObject {
    let relay = RelayClient()

    @Published var lines: [Line] = []
    @Published var dadOnline = false
    @Published var presence: [String: Any] = [:]
    @Published var picture: (kind: String, image: NSImage, at: Date)?
    @Published var waitingFor: String?          // "screenshot" / "camera" while a request is out
    @Published var notice: String?
    @Published var myName: String = UserDefaults.standard.string(forKey: "myName") ?? "Iles" {
        didSet { UserDefaults.standard.set(myName, forKey: "myName"); relay.name = myName; relay.restart() }
    }

    private var player: AVAudioPlayer?
    private var forward: Any?
    let folder: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        folder = support.appendingPathComponent("TTD Family", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("audio"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("pictures"), withIntermediateDirectories: true)
        forward = relay.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        relay.role = "family"
        relay.name = myName
        relay.onMessage = { [weak self] msg in self?.handle(msg) }
        relay.start()
    }

    // MARK: Sending

    func say(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        relay.send(["type": "say", "id": UUID().uuidString, "from": myName, "text": text])
    }

    func request(_ kind: String) {
        waitingFor = kind
        notice = nil
        relay.send(["type": kind, "id": UUID().uuidString])
    }

    func play(_ line: Line) {
        let url = audioURL(line.id)
        if FileManager.default.fileExists(atPath: url.path) {
            player = try? AVAudioPlayer(contentsOf: url)
            player?.play()
        } else {
            notice = "Fetching the recording from Dad's Mac…"
            relay.send(["type": "audio", "id": UUID().uuidString, "lineId": line.id.uuidString])
        }
    }

    func hasAudio(_ line: Line) -> Bool { line.audioFile != nil }

    private func audioURL(_ id: UUID) -> URL { folder.appendingPathComponent("audio/\(id.uuidString).m4a") }

    // MARK: Receiving

    private func handle(_ msg: [String: Any]) {
        switch msg["type"] as? String {
        case "welcome":
            dadOnline = msg["dadOnline"] as? Bool ?? false
            lines = (msg["history"] as? [Any] ?? []).compactMap(decodeLine)
            if let p = msg["presence"] as? [String: Any] { presence = p }
        case "dad":
            dadOnline = msg["online"] as? Bool ?? false
        case "line":
            guard let line = (msg["line"]).flatMap(decodeLine) else { return }
            if let b64 = msg["audio"] as? String, let data = Data(base64Encoded: b64) {
                try? data.write(to: audioURL(line.id))
            }
            if !lines.contains(where: { $0.id == line.id }) { lines.append(line) }
            if line.from == "Dad" {
                NSSound(named: "Glass")?.play()
                if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
            }
        case "presence":
            presence = msg
        case "screenshot", "camera":
            guard let kind = msg["type"] as? String, let b64 = msg["jpeg"] as? String,
                  let data = Data(base64Encoded: b64), let image = NSImage(data: data) else { return }
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            try? data.write(to: folder.appendingPathComponent("pictures/\(kind)-\(stamp).jpg"))
            picture = (kind, image, Date())
            waitingFor = nil
        case "audio":
            guard let id = (msg["lineId"] as? String).flatMap(UUID.init(uuidString:)),
                  let b64 = msg["m4a"] as? String, let data = Data(base64Encoded: b64) else { return }
            try? data.write(to: audioURL(id))
            notice = nil
            player = try? AVAudioPlayer(contentsOf: audioURL(id))
            player?.play()
        case "queued":
            notice = "Dad's Mac is offline. Your message will be spoken when it's back."
        case "error":
            notice = msg["message"] as? String
            waitingFor = nil
        default:
            break
        }
    }

    private func decodeLine(_ any: Any) -> Line? {
        guard let data = try? JSONSerialization.data(withJSONObject: any) else { return nil }
        return try? JSONDecoder.iso.decode(Line.self, from: data)
    }

    // MARK: Presence text

    var presenceSummary: (text: String, colour: Color) {
        guard dadOnline else { return ("Dad's Mac is offline", .gray) }
        if presence["speaking"] as? Bool == true { return ("Speaking to Dad now", .blue) }
        if presence["listening"] as? Bool == true { return ("Listening to Dad now", .green) }
        if presence["locked"] as? Bool == true { return ("Screen locked", .orange) }
        guard let idle = presence["idleSeconds"] as? Int else { return ("Online", .green) }
        let sent = (presence["at"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
        let total = idle + Int(Date().timeIntervalSince(sent))
        if total < 60 { return ("Active now", .green) }
        if total < 3600 { return ("Last active \(total / 60) min ago", total < 600 ? .green : .orange) }
        return ("Last active \(total / 3600) h \(total % 3600 / 60) min ago", .orange)
    }
}

struct FamilyView: View {
    @EnvironmentObject var model: FamilyModel
    @State private var draft = ""
    @State private var showSettings = false
    @State private var tick = Date()

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                header
                Divider()
                chat
                if let notice = model.notice {
                    Text(notice).font(.callout).padding(6).frame(maxWidth: .infinity).background(.yellow.opacity(0.25))
                }
                Divider()
                composer
            }
            .frame(minWidth: 380)
            pictures.frame(minWidth: 240, idealWidth: 340)
        }
        .toolbar {
            ToolbarItem {
                Button { showSettings.toggle() } label: { Label("Settings", systemImage: "gearshape") }
                    .popover(isPresented: $showSettings) { FamilySettings(relay: model.relay).environmentObject(model).padding().frame(width: 420) }
            }
        }
        .onReceive(Timer.publish(every: 20, on: .main, in: .common).autoconnect()) { tick = $0 }
    }

    private var header: some View {
        let p = model.presenceSummary
        return HStack {
            Circle().fill(p.colour).frame(width: 12, height: 12)
            Text(p.text).font(.headline)
            Spacer()
            Text(model.relay.connected ? "Connected" : model.relay.status).font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .id(tick)
    }

    private var chat: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.lines) { line in row(line).id(line.id) }
                }
                .padding()
            }
            .onChange(of: model.lines.count) { proxy.scrollTo(model.lines.last?.id, anchor: .bottom) }
        }
    }

    @ViewBuilder private func row(_ line: Line) -> some View {
        if line.from == "note" {
            Text("\(line.text) · \(line.date.formatted(date: .omitted, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        } else {
            let dad = line.from == "Dad"
            HStack {
                if !dad { Spacer(minLength: 60) }
                VStack(alignment: dad ? .leading : .trailing, spacing: 4) {
                    Text(line.text).font(.title3).textSelection(.enabled).padding(10)
                        .background(dad ? Color.gray.opacity(0.2) : (line.from == "Nicole" ? Color.pink : Color.blue),
                                    in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(dad ? Color.primary : Color.white)
                    HStack(spacing: 6) {
                        Text("\(line.from)\(line.to.map { " → \($0)" } ?? "") · \(line.date.formatted(date: .abbreviated, time: .shortened))")
                        if dad && model.hasAudio(line) {
                            Button { model.play(line) } label: { Label("Play", systemImage: "play.circle") }.buttonStyle(.borderless)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                if dad { Spacer(minLength: 60) }
            }
        }
    }

    private var composer: some View {
        HStack {
            TextField("Message for Dad (spoken on his Mac)…", text: $draft, axis: .vertical)
                .font(.title3).lineLimit(1...5).textFieldStyle(.roundedBorder).onSubmit(send)
            Button("Send", action: send).keyboardShortcut(.return, modifiers: []).controlSize(.large)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding()
    }

    private func send() { model.say(draft); draft = "" }

    private var pictures: some View {
        VStack(spacing: 10) {
            HStack {
                Button { model.request("screenshot") } label: { Label("Screenshot", systemImage: "display") }
                Button { model.request("camera") } label: { Label("Camera", systemImage: "camera") }
            }
            .controlSize(.large)
            .disabled(!model.dadOnline || model.waitingFor != nil)
            if let waiting = model.waitingFor {
                ProgressView("Getting \(waiting) from Dad's Mac…")
            }
            if let pic = model.picture {
                Image(nsImage: pic.image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 8))
                Text("\(pic.kind == "camera" ? "Camera" : "Screen") · \(pic.at.formatted(date: .omitted, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Spacer()
                Text("Take a screenshot or a camera photo to see if Dad is at his computer.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Show saved pictures") { NSWorkspace.shared.open(model.folder.appendingPathComponent("pictures")) }
                .buttonStyle(.link)
        }
        .padding()
    }
}

struct FamilySettings: View {
    @EnvironmentObject var model: FamilyModel
    @ObservedObject var relay: RelayClient
    @State private var key = ""

    var body: some View {
        Form {
            Picker("I am", selection: $model.myName) {
                Text("Iles").tag("Iles")
                Text("Nicole").tag("Nicole")
            }
            TextField("Relay address", text: $relay.url, prompt: Text("https://ttd-relay.example.workers.dev"))
                .onSubmit { relay.restart() }
            HStack {
                SecureField(relay.hasKey ? "Key saved — paste to replace" : "Paste the family key", text: $key)
                Button("Save") { relay.setKey(key); key = "" }.disabled(key.isEmpty)
            }
            Text(relay.status).font(.caption).foregroundStyle(relay.connected ? .green : .secondary)
        }
    }
}
