import Foundation
import FirebaseFirestore

struct FriendRequestModel: Identifiable, Codable, Equatable {
	var id: String
	var fromUid: String
	var toUid: String
	var createdAt: Date
	var status: String // "pending", "accepted", "denied"
	var seen: Bool // Whether the recipient has seen this request
	
	init(id: String = UUID().uuidString, fromUid: String, toUid: String, createdAt: Date = Date(), status: String = "pending", seen: Bool = false) {
		self.id = id
		self.fromUid = fromUid
		self.toUid = toUid
		self.createdAt = createdAt
		self.status = status
		self.seen = seen
	}
	
	init?(document: QueryDocumentSnapshot) {
		let data = document.data()
		guard let fromUid = data["fromUid"] as? String,
			  let toUid = data["toUid"] as? String,
			  let timestamp = data["createdAt"] as? Timestamp else {
			return nil
		}
		
		self.id = document.documentID
		self.fromUid = fromUid
		self.toUid = toUid
		self.createdAt = timestamp.dateValue()
		self.status = data["status"] as? String ?? "pending"
		self.seen = data["seen"] as? Bool ?? false
	}
	
	func toFirestoreData() -> [String: Any] {
		return [
			"fromUid": fromUid,
			"toUid": toUid,
			"createdAt": Timestamp(date: createdAt),
			"status": status,
			"seen": seen
		]
	}
}

