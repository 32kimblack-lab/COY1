import Foundation
import FirebaseFirestore

struct MessageModel: Identifiable, Codable, Equatable {
	var id: String { messageId }
	var messageId: String
	var chatId: String
	var senderUid: String
	var content: String // text or media URL
	var type: String // "text", "image", "video", "live_photo", "voice"
	var timestamp: Date
	var isDeleted: Bool
	var isEdited: Bool
	var editedAt: Date?
	var reactions: [String: String] // [uid: emoji]
	var replyToMessageId: String?
	var deletedFor: [String] // for Clear Chat (one-sided delete)
	
	init(messageId: String = UUID().uuidString, chatId: String, senderUid: String, content: String, type: String, timestamp: Date = Date(), isDeleted: Bool = false, isEdited: Bool = false, editedAt: Date? = nil, reactions: [String: String] = [:], replyToMessageId: String? = nil, deletedFor: [String] = []) {
		self.messageId = messageId
		self.chatId = chatId
		self.senderUid = senderUid
		self.content = content
		self.type = type
		self.timestamp = timestamp
		self.isDeleted = isDeleted
		self.isEdited = isEdited
		self.editedAt = editedAt
		self.reactions = reactions
		self.replyToMessageId = replyToMessageId
		self.deletedFor = deletedFor
	}
	
	init?(document: QueryDocumentSnapshot) {
		let data = document.data()
		guard let chatId = data["chatId"] as? String,
			  let senderUid = data["senderUid"] as? String,
			  let timestamp = data["timestamp"] as? Timestamp else {
			return nil
		}
		
		self.messageId = document.documentID
		self.chatId = chatId
		self.senderUid = senderUid
		self.content = data["content"] as? String ?? ""
		self.type = data["type"] as? String ?? "text"
		self.timestamp = timestamp.dateValue()
		self.isDeleted = data["isDeleted"] as? Bool ?? false
		self.isEdited = data["isEdited"] as? Bool ?? false
		
		if let editedTimestamp = data["editedAt"] as? Timestamp {
			self.editedAt = editedTimestamp.dateValue()
		}
		
		if let reactionsDict = data["reactions"] as? [String: String] {
			self.reactions = reactionsDict
		} else {
			self.reactions = [:]
		}
		
		self.replyToMessageId = data["replyToMessageId"] as? String
		
		if let deletedForArray = data["deletedFor"] as? [String] {
			self.deletedFor = deletedForArray
		} else {
			self.deletedFor = []
		}
	}
	
	func toFirestoreData() -> [String: Any] {
		var data: [String: Any] = [
			"chatId": chatId,
			"senderUid": senderUid,
			"content": content,
			"type": type,
			"timestamp": Timestamp(date: timestamp),
			"isDeleted": isDeleted,
			"isEdited": isEdited,
			"reactions": reactions,
			"deletedFor": deletedFor
		]
		
		if let editedAt = editedAt {
			data["editedAt"] = Timestamp(date: editedAt)
		}
		
		if let replyTo = replyToMessageId {
			data["replyToMessageId"] = replyTo
		}
		
		return data
	}
	
	// MARK: - Equatable
	static func == (lhs: MessageModel, rhs: MessageModel) -> Bool {
		return lhs.messageId == rhs.messageId
	}
}

