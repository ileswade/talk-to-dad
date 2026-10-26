import AppKit
import Foundation

/// Optionally sends Dad's spoken answers back by iMessage, from his Mac, to whoever he was talking to.
/// Off by default. Uses AppleScript to drive Messages (macOS asks once for Automation permission).
final class MessagesSender: ObservableObject {
    enum Mode: String, CaseIterable { case off, text, textAndAudio }

    @Published var mode: Mode = Mode(rawValue: UserDefaults.standard.string(forKey: "sendReplies") ?? "") ?? .off {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "sendReplies") }
    }
    @Published var problem: String?

    private let queue = DispatchQueue(label: "ttd.messages-sender")

    /// `number` like "403-555-0123". `audio` is the recording of his answer, if any.
    func send(_ text: String, to number: String, audio: URL?) {
        guard mode != .off else { return }
        let digits = String(number.filter(\.isNumber).suffix(10))
        guard digits.count == 10 else { return }
        let handle = "+1" + digits
        var script = """
            tell application "Messages"
              set svc to 1st account whose service type = iMessage
              set who to participant "\(handle)" of svc
              send "\(Self.escape(text))" to who
            """
        if mode == .textAndAudio, let audio {
            script += "\n  send POSIX file \"\(Self.escape(audio.path))\" to who"
        }
        script += "\nend tell"
        queue.async {
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            DispatchQueue.main.async {
                self.problem = error.map { _ in
                    "Couldn't send Dad's answer by text. Check that Messages is signed in, and allow Talk to Dad under System Settings → Privacy & Security → Automation → Messages."
                }
            }
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
