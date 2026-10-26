import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI
import TTDShared

@main
struct TalkToDadApp: App {
    @StateObject private var model = ChatModel()

    var body: some Scene {
        Window("Talk to Dad", id: "chat") {
            ChatView().environmentObject(model)
                .frame(minWidth: 520, minHeight: 560)
        }
        .defaultSize(width: 640, height: 760)
        .defaultLaunchBehavior(.suppressed)   // starts quietly in the menu bar

        MenuBarExtra {
            OpenChatButton()
            Divider()
            Button("Quit Talk to Dad") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: model.menuIcon)
        }
    }
}

struct OpenChatButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Open Talk to Dad") {
            openWindow(id: "chat")
            NSApp.activate()
        }
    }
}

/// Ties typing, speaking and listening together.
final class ChatModel: ObservableObject {
    let store = ConversationStore()
    let speaker = Speaker()
    let listener = Listener()
    let texts = MessagesWatcher()
    let replies = MessagesSender()
    let relay = RelayClient()
    let updater = Updater()
    private var waiting: [MessagesWatcher.Incoming] = []   // texts that arrived while busy

    @Published var announce: Bool = UserDefaults.standard.object(forKey: "announce") as? Bool ?? true {
        didSet { UserDefaults.standard.set(announce, forKey: "announce") }
    }
    @Published var autoListen: Bool = UserDefaults.standard.object(forKey: "autoListen") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoListen, forKey: "autoListen") }
    }
    @Published var permissionProblem: String?
    /// Who Dad is talking to while listening.
    @Published var listeningTo: String?

    /// Who is typing. Each person has their own voice and "Message from …".
    static let senders = ["Iles", "Nicole"]
    static let defaultVoices = ["Iles": "am_adam", "Nicole": "af_heart"]
    @Published var sender: String = UserDefaults.standard.string(forKey: "sender") ?? "Iles" {
        didSet { UserDefaults.standard.set(sender, forKey: "sender") }
    }
    func voice(for name: String) -> String {
        UserDefaults.standard.string(forKey: "voice.\(name)") ?? Self.defaultVoices[name] ?? "am_adam"
    }
    func setVoice(_ id: String, for name: String) {
        UserDefaults.standard.set(id, forKey: "voice.\(name)")
        objectWillChange.send()
    }

    /// Menu bar app that starts with the Mac. Turned on the first time the app runs.
    @Published var startAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet {
            guard startAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if startAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                permissionProblem = "Couldn't change start-at-login: \(error.localizedDescription)"
            }
        }
    }

    private var player: AVAudioPlayer?
    private var forward: [Any] = []

    init() {
        // Re-publish changes from the parts so the views refresh.
        forward = [store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
                   speaker.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
                   listener.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
                   texts.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
                   replies.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
                   relay.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }]
        speaker.prepare()
        if ProcessInfo.processInfo.environment["TALKTODAD_SELFTEST"] != nil { return }   // voice test only
        texts.onMessage = { [weak self] msg in self?.received(msg) }
        texts.start()
        startRelay()
        updater.onStatus = { [weak self] text in self?.relay.send(["type": "update", "status": text, "version": Updater.currentVersion]) }
        updater.start()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.playWaiting() }
        Listener.requestPermissions { [weak self] problem in self?.permissionProblem = problem }
        if !UserDefaults.standard.bool(forKey: "loginItemSetUp") {
            UserDefaults.standard.set(true, forKey: "loginItemSetUp")
            try? SMAppService.mainApp.register()   // property observers don't run inside init
            startAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    var status: String {
        if speaker.isSpeaking { return "Speaking…" }
        if listener.isListening { return listener.partial.isEmpty ? "Listening — waiting for Dad to speak…" : "Listening…" }
        return "Ready"
    }

    var menuIcon: String {
        speaker.isSpeaking ? "speaker.wave.2.fill" : listener.isListening ? "ear.fill" : "bubble.left.and.bubble.right"
    }

    func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        listener.cancel()
        store.add(Line(from: sender, text: text))
        say(text, from: sender)
    }

    func repeatLast() {
        guard let last = store.lines.last(where: { $0.from != "Dad" && $0.from != "note" }) else { return }
        listener.cancel()
        say(last.text, from: last.from)
    }

    /// A chat session is a run of back-and-forth with no gap longer than `sessionMinutes`.
    /// Only the first message of a session gets the chime and "Message from Iles".
    @Published var sessionMinutes: Double = UserDefaults.standard.object(forKey: "sessionMinutes") as? Double ?? 5 {
        didSet { UserDefaults.standard.set(sessionMinutes, forKey: "sessionMinutes") }
    }
    private var lastActivity = Date.distantPast
    private var lastSender = ""

    private var inSession: Bool { Date().timeIntervalSince(lastActivity) < sessionMinutes * 60 }

    private func say(_ text: String, from who: String) {
        let opening = !inSession || who != lastSender   // a new person starts a new chat
        lastActivity = Date()
        lastSender = who
        if opening { NSSound(named: "Glass")?.play() }
        let spoken = opening && announce ? "Message from \(who). \(text)" : text
        DispatchQueue.main.asyncAfter(deadline: .now() + (opening ? 0.8 : 0.1)) {
            self.speaker.speak(spoken, voice: self.voice(for: who)) { [weak self] in
                guard let self else { return }
                self.lastActivity = Date()
                if self.autoListen { self.listen(to: who) }
            }
        }
    }

    func listen(to who: String? = nil) {
        guard !listener.isListening, !speaker.isSpeaking else { return }
        let who = who ?? (lastSender.isEmpty ? sender : lastSender)
        listeningTo = who
        NSSound(named: "Tink")?.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.listener.start(recordTo: self.store.newAudioURL()) { [weak self] text, url in
                guard let self else { return }
                self.listeningTo = nil
                if !text.isEmpty || url != nil { self.lastActivity = Date() }
                if text.isEmpty, let url {
                    self.store.add(Line(from: "Dad", text: "(Couldn't make out the words — play the recording)", audioFile: url.lastPathComponent, to: who))
                } else if text.isEmpty {
                    self.store.add(Line(from: "note", text: "No answer heard."))
                } else {
                    self.store.add(Line(from: "Dad", text: text, audioFile: url?.lastPathComponent, to: who))
                    self.replies.send(text, to: self.texts.number(for: who), audio: url)
                }
            }
        }
    }

    /// A text from Iles or Nicole arrived in Messages: show it and read it aloud (after anything in progress).
    func received(_ msg: MessagesWatcher.Incoming) {
        waiting.append(msg)
        playWaiting()
    }

    private func playWaiting() {
        guard !waiting.isEmpty, !speaker.isSpeaking, !listener.isListening else { return }
        let msg = waiting.removeFirst()
        store.add(Line(date: msg.date, from: msg.from, text: msg.text))
        say(msg.text, from: msg.from)
    }

    /// Dad pressed "Talk to Iles" or "Talk to Nicole": stop any speech and listen to him.
    func dadStartsTalking(to who: String) {
        if speaker.isSpeaking { speaker.stop() }
        lastActivity = Date()
        lastSender = who
        listen(to: who)
    }

    // MARK: - Relay: the family app reaches Dad's Mac from anywhere

    private var lastPresence: [String: Any] = [:]

    private func startRelay() {
        relay.role = "dad"
        relay.onConnect = { [weak self] in self?.sendPresence(force: true) }
        relay.onMessage = { [weak self] msg in self?.fromFamily(msg) }
        store.onAdd = { [weak self] line in self?.forward(line) }
        relay.start()
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.sendPresence(force: false) }
    }

    /// Every new chat line goes to the family app; Dad's lines carry their recording.
    private func forward(_ line: Line) {
        guard let data = try? JSONEncoder.iso.encode(line),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return }
        var msg: [String: Any] = ["type": "line", "line": obj]
        if let url = store.audioURL(for: line), let audio = try? Data(contentsOf: url), audio.count < 6_000_000 {
            msg["audio"] = audio.base64EncodedString()
        }
        relay.send(msg)
    }

    private func sendPresence(force: Bool) {
        let idle = Int(Presence.idleSeconds)
        let p: [String: Any] = ["type": "presence", "version": Updater.currentVersion, "idleSeconds": idle, "locked": Presence.screenLocked,
                                "speaking": speaker.isSpeaking, "listening": listener.isListening,
                                "at": Int(Date().timeIntervalSince1970 * 1000)]
        // Send when something meaningful changed (or every few minutes to keep "last seen" fresh).
        let was = lastPresence["idleSeconds"] as? Int ?? -1
        let changed = force || (was < 60) != (idle < 60) || (lastPresence["locked"] as? Bool) != Presence.screenLocked
            || (lastPresence["speaking"] as? Bool) != speaker.isSpeaking || (lastPresence["listening"] as? Bool) != listener.isListening
            || idle < was || idle % 300 < 15
        guard changed else { return }
        lastPresence = p
        relay.send(p)
    }

    private func fromFamily(_ msg: [String: Any]) {
        let id = msg["id"] as? String ?? UUID().uuidString
        let from = msg["from"] as? String ?? "Iles"
        switch msg["type"] as? String {
        case "say":
            guard let text = msg["text"] as? String, !text.isEmpty else { return }
            let name = Self.senders.contains(from) ? from : "Iles"
            received(MessagesWatcher.Incoming(from: name, text: text, date: Date()))
        case "screenshot":
            Task {
                do {
                    let jpeg = try await Presence.screenshot()
                    await MainActor.run { self.relay.send(["type": "screenshot", "id": id, "for": from, "jpeg": jpeg.base64EncodedString()]) }
                } catch {
                    await MainActor.run { self.relay.send(["type": "error", "id": id, "for": from,
                        "message": "Screenshot not allowed yet: on Dad's Mac, System Settings → Privacy & Security → Screen Recording → Talk to Dad."]) }
                }
            }
        case "camera":
            CameraSnapshot.take { [weak self] jpeg in
                DispatchQueue.main.async {
                    if let jpeg {
                        self?.relay.send(["type": "camera", "id": id, "for": from, "jpeg": jpeg.base64EncodedString()])
                    } else {
                        self?.relay.send(["type": "error", "id": id, "for": from,
                            "message": "Camera not available or not allowed: System Settings → Privacy & Security → Camera → Talk to Dad."])
                    }
                }
            }
        case "audio":
            guard let lineID = msg["lineId"] as? String,
                  let line = store.lines.first(where: { $0.id.uuidString == lineID }),
                  let url = store.audioURL(for: line), let audio = try? Data(contentsOf: url) else { return }
            relay.send(["type": "audio", "id": id, "lineId": lineID, "m4a": audio.base64EncodedString()])
        case "presence?":
            sendPresence(force: true)
        case "update":
            updater.check(install: true)
        default:
            break
        }
    }

    func play(_ line: Line) {
        guard let url = store.audioURL(for: line) else { return }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
    }
}
