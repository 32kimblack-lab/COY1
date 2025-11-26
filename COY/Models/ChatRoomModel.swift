import Foundation
import FirebaseFirestore

struct ChatRoomModel: Identifiable, Codable {
	var id: String { chatId }
	var chatId: String
	var participants: [String]
	var lastMessageTs: Date
	var lastMessage: String
	var lastMessageType: String // "text", "image", "video", "live_photo", "voice"
	var unreadCount: [String: Int] // [uid: count]
	var chatStatus: [String: String] // [uid: "friends" | "unadded" | "pending"] - tracks friendship status per user
	
	init(chatId: String, participants: [String], lastMessageTs: Date = Date(), lastMessage: String = "", lastMessageType: String = "text", unreadCount: [String: Int] = [:], chatStatus: [String: String] = [:]) {
		self.chatId = chatId
		self.participants = participants
		self.lastMessageTs = lastMessageTs
		self.lastMessage = lastMessage
		self.lastMessageType = lastMessageType
		self.unreadCount = unreadCount
		self.chatStatus = chatStatus
	}
	
	init?(document: DocumentSnapshot) {
		guard let data = document.data(),
			  let participants = data["participants"] as? [String],
			  let timestamp = data["lastMessageTs"] as? Timestamp else {
			return nil
		}
		
		self.chatId = document.documentID
		self.participants = participants
		self.lastMessageTs = timestamp.dateValue()
		self.lastMessage = data["lastMessage"] as? String ?? ""
		self.lastMessageType = data["lastMessageType"] as? String ?? "text"
		
		if let unreadDict = data["unreadCount"] as? [String: Int] {
			self.unreadCount = unreadDict
		} else {
			self.unreadCount = [:]
		}
		
		if let statusDict = data["chatStatus"] as? [String: String] {
			self.chatStatus = statusDict
		} else {
			// Default to "friends" for both participants if not set (backward compatibility)
			self.chatStatus = [participants[0]: "friends", participants[1]: "friends"]
		}
	}
	
	init?(queryDocument: QueryDocumentSnapshot) {
		let data = queryDocument.data()
		guard let participants = data["participants"] as? [String],
			  let timestamp = data["lastMessageTs"] as? Timestamp else {
			return nil
		}
		
		self.chatId = queryDocument.documentID
		self.participants = participants
		self.lastMessageTs = timestamp.dateValue()
		self.lastMessage = data["lastMessage"] as? String ?? ""
		self.lastMessageType = data["lastMessageType"] as? String ?? "text"
		
		if let unreadDict = data["unreadCount"] as? [String: Int] {
			self.unreadCount = unreadDict
		} else {
			self.unreadCount = [:]
		}
		
		if let statusDict = data["chatStatus"] as? [String: String] {
			self.chatStatus = statusDict
		} else {
			// Default to "friends" for both participants if not set (backward compatibility)
			self.chatStatus = [participants[0]: "friends", participants[1]: "friends"]
		}
	}
	
	func toFirestoreData() -> [String: Any] {
		return [
			"participants": participants,
			"lastMessageTs": Timestamp(date: lastMessageTs),
			"lastMessage": lastMessage,
			"lastMessageType": lastMessageType,
			"unreadCount": unreadCount,
			"chatStatus": chatStatus
		]
	}
}

