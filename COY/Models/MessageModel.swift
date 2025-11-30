import Foundation
import FirebaseFirestore

struct MessageModel: Identifiable, Codable, Equatable, Hashable {
	var id: String { messageId }
	var messageId: String
	var chatId: String
	var senderUid: String
	var content: String // text or media URL
	var type: String // "text", "image", "video", "live_photo"
	var timestamp: Date
	var isDeleted: Bool
	var isEdited: Bool
	var editedAt: Date?
	var editCount: Int // Number of times message has been edited (max 2)
	var reactions: [String: String] // [uid: emoji]
	var replyToMessageId: String?
	var deletedFor: [String] // for Clear Chat (one-sided delete)
	var deliveredTo: [String] // User IDs who have received the message
	var readBy: [String] // User IDs who have read the message
	
	init(messageId: String = UUID().uuidString, chatId: String, senderUid: String, content: String, type: String, timestamp: Date = Date(), isDeleted: Bool = false, isEdited: Bool = false, editedAt: Date? = nil, editCount: Int = 0, reactions: [String: String] = [:], replyToMessageId: String? = nil, deletedFor: [String] = [], deliveredTo: [String] = [], readBy: [String] = []) {
		self.messageId = messageId
		self.chatId = chatId
		self.senderUid = senderUid
		self.content = content
		self.type = type
		self.timestamp = timestamp
		self.isDeleted = isDeleted
		self.isEdited = isEdited
		self.editedAt = editedAt
		self.editCount = editCount
		self.reactions = reactions
		self.replyToMessageId = replyToMessageId
		self.deletedFor = deletedFor
		self.deliveredTo = deliveredTo
		self.readBy = readBy
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
		self.editCount = data["editCount"] as? Int ?? 0
		
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
		
		if let deliveredToArray = data["deliveredTo"] as? [String] {
			self.deliveredTo = deliveredToArray
		} else {
			self.deliveredTo = []
		}
		
		if let readByArray = data["readBy"] as? [String] {
			self.readBy = readByArray
		} else {
			self.readBy = []
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
			"editCount": editCount,
			"reactions": reactions,
			"deletedFor": deletedFor,
			"deliveredTo": deliveredTo,
			"readBy": readBy
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
	// Explicit implementation to ensure SwiftUI detects changes to content, reactions, edits, etc.
	static func == (lhs: MessageModel, rhs: MessageModel) -> Bool {
		return lhs.messageId == rhs.messageId &&
			   lhs.content == rhs.content &&
			   lhs.reactions == rhs.reactions &&
			   lhs.isEdited == rhs.isEdited &&
			   lhs.editCount == rhs.editCount &&
			   lhs.isDeleted == rhs.isDeleted &&
			   lhs.editedAt == rhs.editedAt &&
			   lhs.replyToMessageId == rhs.replyToMessageId &&
			   lhs.deletedFor == rhs.deletedFor &&
			   lhs.deliveredTo == rhs.deliveredTo &&
			   lhs.readBy == rhs.readBy
	}
	
	// MARK: - Hashable
	func hash(into hasher: inout Hasher) {
		hasher.combine(messageId)
		hasher.combine(content)
		hasher.combine(reactions)
		hasher.combine(isEdited)
		hasher.combine(editCount)
		hasher.combine(isDeleted)
		hasher.combine(editedAt)
		hasher.combine(replyToMessageId)
		hasher.combine(deletedFor)
		hasher.combine(deliveredTo)
		hasher.combine(readBy)
	}
}

