import Foundation
import TTDShared

/// Keeps the conversation on this Mac: ~/Library/Application Support/Talk to Dad/Conversation/
/// (conversation.jsonl plus audio/). Not ~/Documents, which would trigger a privacy prompt.
final class ConversationStore: ObservableObject {
    @Published private(set) var lines: [Line] = []
    /// "Clear" hides everything before this moment. The history stays saved on disk.
    @Published private(set) var clearedAt: Date = UserDefaults.standard.object(forKey: "clearedAt") as? Date ?? .distantPast

    var visibleLines: [Line] { lines.filter { $0.date > clearedAt } }

    func clearScreen() {
        clearedAt = Date()
        UserDefaults.standard.set(clearedAt, forKey: "clearedAt")
    }

    let folder: URL
    let audioFolder: URL
    private let logFile: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        folder = support.appendingPathComponent("Talk to Dad/Conversation", isDirectory: true)
        // Carry over a conversation saved by an earlier version in ~/Documents.
        let old = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Talk to Dad")
        if !FileManager.default.fileExists(atPath: folder.path), FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.moveItem(at: old, to: folder)
        }
        audioFolder = folder.appendingPathComponent("audio", isDirectory: true)
        logFile = folder.appendingPathComponent("conversation.jsonl")
        try? FileManager.default.createDirectory(at: audioFolder, withIntermediateDirectories: true)
        load()
    }

    func newAudioURL() -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return audioFolder.appendingPathComponent("dad-\(f.string(from: Date())).m4a")
    }

    func audioURL(for line: Line) -> URL? {
        line.audioFile.map { audioFolder.appendingPathComponent($0) }
    }

    /// Called for every new line (TTD forwards it to the relay).
    var onAdd: ((Line) -> Void)?

    func add(_ line: Line) {
        lines.append(line)
        onAdd?(line)
        guard let data = try? JSONEncoder.iso.encode(line) else { return }
        if let h = try? FileHandle(forWritingTo: logFile) {
            h.seekToEndOfFile()
            h.write(data + Data("\n".utf8))
            try? h.close()
        } else {
            try? (data + Data("\n".utf8)).write(to: logFile)
        }
    }

    private func load() {
        guard let text = try? String(contentsOf: logFile, encoding: .utf8) else { return }
        lines = text.split(separator: "\n").compactMap { try? JSONDecoder.iso.decode(Line.self, from: Data($0.utf8)) }
    }
}

