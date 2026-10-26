import Foundation

/// One line in the chat: something Iles typed, or something Dad said.
public struct Line: Identifiable, Codable, Equatable {
    public var id = UUID()
    public var date = Date()
    public var from: String          // "Iles", "Dad" or "note"
    public var text: String
    public var audioFile: String?    // file name inside the audio folder, for Dad's replies
    public var to: String? = nil     // for Dad's lines: who he was talking to (Iles or Nicole)

    public init(id: UUID = UUID(), date: Date = Date(), from: String, text: String, audioFile: String? = nil, to: String? = nil) {
        self.id = id; self.date = date; self.from = from; self.text = text; self.audioFile = audioFile; self.to = to
    }
}

extension JSONEncoder {
    public static let iso: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
}
extension JSONDecoder {
    public static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
