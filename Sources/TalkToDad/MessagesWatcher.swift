import Foundation
import SQLite3

/// Watches Messages on this Mac for new iMessages/texts from Iles and Nicole and hands them to TTD.
/// Reads ~/Library/Messages/chat.db read-only (needs Full Disk Access). Never sends anything.
final class MessagesWatcher: ObservableObject {
    struct Incoming { let from: String; let text: String; let date: Date }

    /// People whose texts are read aloud. Their phone numbers are entered in Settings on Dad's Mac
    /// (not stored in the code). Matched on the last 10 digits.
    static let defaultPeople = ["Iles": "", "Nicole": ""]

    @Published var enabled: Bool = UserDefaults.standard.object(forKey: "readTexts") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "readTexts"); enabled ? start() : stop() }
    }
    /// Testing on Iles's own Mac: also read messages *sent* to Iles's or Nicole's number (texting yourself).
    @Published var testMode: Bool = UserDefaults.standard.bool(forKey: "textsTestMode") {
        didSet { UserDefaults.standard.set(testMode, forKey: "textsTestMode") }
    }
    @Published var problem: String?
    @Published var lastChecked: Date?

    var onMessage: ((Incoming) -> Void)?

    private let dbPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db").path
    private var timer: Timer?
    private var lastDelivered: (text: String, date: Date)?
    /// Messages dates are nanoseconds since 2001-01-01. Only messages after this are ever read.
    private var lastDate: Int64 = 0

    func number(for name: String) -> String {
        UserDefaults.standard.string(forKey: "phone.\(name)") ?? Self.defaultPeople[name] ?? ""
    }

    func setNumber(_ number: String, for name: String) {
        UserDefaults.standard.set(number, forKey: "phone.\(name)")
        objectWillChange.send()
    }

    private var people: [(name: String, digits: String)] {
        Self.defaultPeople.keys.sorted().map { ($0, Self.lastTen(number(for: $0))) }.filter { !$0.digits.isEmpty }
    }

    static func lastTen(_ s: String) -> String {
        String(s.filter(\.isNumber).suffix(10))
    }

    func start() {
        guard enabled, timer == nil else { return }
        // Only texts that arrive from now on (2 minutes' grace). History is never read.
        lastDate = max(lastDate, Int64(Date().addingTimeInterval(-120).timeIntervalSinceReferenceDate * 1_000_000_000))
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.check() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func check() {
        let sql = """
            SELECT m.ROWID, h.id, m.text, m.attributedBody, m.date, m.cache_has_attachments, m.is_from_me
            FROM message m JOIN handle h ON m.handle_id = h.ROWID
            WHERE (m.is_from_me = 0 OR \(testMode ? 1 : 0) = 1) AND m.date > \(lastDate)
              AND IFNULL(m.associated_message_type, 0) = 0
            ORDER BY m.date LIMIT 50
            """
        let rows: [(Int64, String, String?, Data?, Int64, Bool, Bool)] = query(sql) { st in
            let id = sqlite3_column_int64(st, 0)
            let handle = sqlite3_column_text(st, 1).map { String(cString: $0) } ?? ""
            let text = sqlite3_column_text(st, 2).map { String(cString: $0) }
            var body: Data?
            if let blob = sqlite3_column_blob(st, 3) {
                body = Data(bytes: blob, count: Int(sqlite3_column_bytes(st, 3)))
            }
            return (id, handle, text, body, sqlite3_column_int64(st, 4), sqlite3_column_int(st, 5) != 0, sqlite3_column_int(st, 6) != 0)
        }
        guard problem == nil || !rows.isEmpty || lastChecked != nil else { return }
        lastChecked = Date()
        for (id, handle, text, body, appleDate, hasAttachment, fromMe) in rows {
            lastDate = max(lastDate, appleDate)
            let digits = Self.lastTen(handle)
            guard let person = people.first(where: { !digits.isEmpty && $0.digits == digits }) else { continue }
            if fromMe && person.name != "Iles" { continue }   // test mode: only texts to yourself, never ones you send Nicole
            var words = (text ?? Self.decode(body) ?? "")
                .replacingOccurrences(of: "\u{FFFC}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if words.isEmpty && hasAttachment { words = "sent you a picture or a file. Have a look on your phone." }
            guard !words.isEmpty else { continue }
            // Messages stores dates as nanoseconds since 2001-01-01.
            let date = Date(timeIntervalSinceReferenceDate: Double(appleDate) / 1_000_000_000)
            // Texting yourself can store the same message twice (sent + received copy).
            if let last = lastDelivered, last.text == words, abs(last.date.timeIntervalSince(date)) < 10 { continue }
            lastDelivered = (words, date)
            onMessage?(Incoming(from: person.name, text: words, date: date))
        }
    }

    /// Newer macOS keeps the text in `attributedBody` (an archived NSAttributedString).
    static func decode(_ data: Data?) -> String? {
        guard let data else { return nil }
        if let s = (try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: data))?.string { return s }
        return (NSUnarchiver.unarchiveObject(with: data) as? NSAttributedString)?.string
    }

    private func query<T>(_ sql: String, _ row: (OpaquePointer) -> T) -> [T] {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(dbPath, &db, flags, nil) == SQLITE_OK, let db else {
            setProblem()
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else {
            setProblem()
            return []
        }
        defer { sqlite3_finalize(st) }
        var out: [T] = []
        while sqlite3_step(st) == SQLITE_ROW { out.append(row(st)) }
        if problem != nil { DispatchQueue.main.async { self.problem = nil } }
        return out
    }

    private func setProblem() {
        DispatchQueue.main.async {
            self.problem = "To read texts from Iles and Nicole aloud, allow Talk to Dad in System Settings → Privacy & Security → Full Disk Access, then reopen it."
        }
    }
}
