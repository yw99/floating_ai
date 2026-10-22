import Foundation

public struct TranscriptMessage: Identifiable, Equatable, Sendable {
    public var id: String
    public var role: String
    public var text: String
    public var imagePaths: [String]
    public var fileAttachments: [StoredAttachment]
    public init(id: String, role: String, text: String, imagePaths: [String] = [], fileAttachments: [StoredAttachment] = []) {
        self.id = id; self.role = role; self.text = text; self.imagePaths = imagePaths; self.fileAttachments = fileAttachments
    }
}

public enum Transcript {
    public static func message(from item: JSONValue) -> TranscriptMessage? {
        guard let id = item["id"].stringValue, let type = item["type"].stringValue else { return nil }
        switch type {
        case "agentMessage":
            return TranscriptMessage(id: id, role: "assistant", text: item["text"].stringValue ?? "")
        case "userMessage":
            let content = item["content"].arrayValue ?? []
            let text = content.filter { $0["type"].stringValue == "text" }
                .compactMap { $0["text"].stringValue }.joined(separator: "\n")
            let images = content.compactMap { value -> String? in
                guard value["type"].stringValue == "localImage" else { return nil }
                return value["path"].stringValue
            }
            let decoded = AttachmentMessage.decode(text)
            return TranscriptMessage(id: id, role: "user", text: decoded.text, imagePaths: images, fileAttachments: decoded.files)
        default: return nil
        }
    }
    public static func messages(from response: JSONValue) -> [TranscriptMessage] {
        let thread = response["thread"] == .null ? response : response["thread"]
        return (thread["turns"].arrayValue ?? []).flatMap { turn in
            (turn["items"].arrayValue ?? []).compactMap(message(from:))
        }
    }
    public static func upsert(_ message: TranscriptMessage, into messages: inout [TranscriptMessage]) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        } else { messages.append(message) }
    }
    public static func append(delta: String, itemID: String, to messages: inout [TranscriptMessage]) {
        if let index = messages.firstIndex(where: { $0.id == itemID }) {
            messages[index].text += delta
        } else {
            messages.append(TranscriptMessage(id: itemID, role: "assistant", text: delta))
        }
    }
}
