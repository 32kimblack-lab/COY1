import Foundation
import FirebaseFirestore
import FirebaseAuth

@MainActor
final class NotificationService {
	static let shared = NotificationService()
	private init() {}
	
	// MARK: - Notification Model
	struct AppNotification: Identifiable {
		var id: String
		var type: String // "collection_request", "follow", "collection_join", etc.
		var userId: String // User who triggered the notification
		var username: String
		var userProfileImageURL: String?
		var collectionId: String? // For collection requests
		var collectionName: String? // For collection requests
		var message: String
		var isRead: Bool
		var createdAt: Date
		var status: String? // "pending", "accepted", "denied" for requests
		var joinedUsers: [[String: Any]]? // For batch join notifications
		var joinCount: Int? // Number of users who joined
	}
	
	// MARK: - Send Collection Request Notification
	func sendCollectionRequestNotification(
		collectionId: String,
		collectionName: String,
		requesterId: String,
		requesterUsername: String,
		requesterProfileImageURL: String?
	) async throws {
		guard let currentUserId = Auth.auth().currentUser?.uid else {
			throw NSError(domain: "NotificationService", code: -1, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])
		}
		
		// Get collection to find owner and admins
		guard let collection = try await CollectionService.shared.getCollection(collectionId: collectionId) else {
			throw NSError(domain: "NotificationService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Collection not found"])
		}
		
		let db = Firestore.firestore()
		
		// Get all admins (owners array)
		let admins = collection.owners
		
		// Create or update notification for each admin (ONE notification per admin, not multiple)
		for adminId in admins {
			// Skip if requester is the admin
			if adminId == currentUserId {
				continue
			}
			
			// Check if notification already exists
			let notificationsRef = db.collection("users")
				.document(adminId)
				.collection("notifications")
			
			// Query for existing pending request notification from this user for this collection
			let existingQuery = notificationsRef
				.whereField("type", isEqualTo: "collection_request")
				.whereField("userId", isEqualTo: currentUserId)
				.whereField("collectionId", isEqualTo: collectionId)
				.whereField("status", isEqualTo: "pending")
				.limit(to: 1)
			
			let existingSnapshot = try? await existingQuery.getDocuments()
			
			let notificationData: [String: Any] = [
				"type": "collection_request",
				"userId": currentUserId,
				"username": requesterUsername,
				"userProfileImageURL": requesterProfileImageURL ?? "",
				"collectionId": collectionId,
				"collectionName": collectionName,
				"message": "\(requesterUsername) requested to join \(collectionName)",
				"isRead": false,
				"status": "pending",
				"createdAt": Timestamp()
			]
			
			if let existingDoc = existingSnapshot?.documents.first {
				// Update existing notification instead of creating a new one
				try await existingDoc.reference.updateData(notificationData)
				print("✅ NotificationService: Updated existing collection request notification for admin: \(adminId)")
			} else {
				// Create new notification
				let notificationRef = notificationsRef.document()
			try await notificationRef.setData(notificationData)
			print("✅ NotificationService: Sent collection request notification to admin: \(adminId)")
			}
		}
		
		// Post notification to trigger UI update
		await MainActor.run {
			NotificationCenter.default.post(
				name: NSNotification.Name("CollectionRequestSent"),
				object: collectionId,
				userInfo: ["requesterId": currentUserId]
			)
		}
	}
	
	// MARK: - Cancel Collection Request Notification
	func cancelCollectionRequestNotification(
		collectionId: String,
		requesterId: String
	) async throws {
		guard let currentUserId = Auth.auth().currentUser?.uid else {
			throw NSError(domain: "NotificationService", code: -1, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])
		}
		
		// Get collection to find owner and admins
		guard let collection = try await CollectionService.shared.getCollection(collectionId: collectionId) else {
			throw NSError(domain: "NotificationService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Collection not found"])
		}
		
		let db = Firestore.firestore()
		
		// Get all admins (owners array)
		let admins = collection.owners
		
		// Delete notification for each admin
		for adminId in admins {
			// Skip if requester is the admin
			if adminId == currentUserId {
				continue
			}
			
			let notificationsRef = db.collection("users")
				.document(adminId)
				.collection("notifications")
			
			// Find and delete pending request notification from this user for this collection
			let query = notificationsRef
				.whereField("type", isEqualTo: "collection_request")
				.whereField("userId", isEqualTo: currentUserId)
				.whereField("collectionId", isEqualTo: collectionId)
				.whereField("status", isEqualTo: "pending")
			
			let snapshot = try? await query.getDocuments()
			
			// Delete all matching notifications (should only be one, but delete all to be safe)
			for doc in snapshot?.documents ?? [] {
				try await doc.reference.delete()
				print("✅ NotificationService: Deleted collection request notification for admin: \(adminId)")
			}
		}
		
		// Post notification to trigger UI update
		await MainActor.run {
			NotificationCenter.default.post(
				name: NSNotification.Name("CollectionRequestCancelled"),
				object: collectionId,
				userInfo: ["requesterId": currentUserId]
			)
		}
	}
	
	// MARK: - Get Notifications
	func getNotifications(userId: String) async throws -> [AppNotification] {
		let db = Firestore.firestore()
		let snapshot = try await db.collection("users")
			.document(userId)
			.collection("notifications")
			.order(by: "createdAt", descending: true)
			.limit(to: 50)
			.getDocuments()
		
		// Auto-delete notifications older than 24 hours
		let now = Date()
		let twentyFourHoursAgo = now.addingTimeInterval(-24 * 60 * 60)
		
		var notifications: [AppNotification] = []
		var notificationsToDelete: [String] = []
		
		for doc in snapshot.documents {
			let data = doc.data()
			guard let type = data["type"] as? String,
				  let userId = data["userId"] as? String,
				  let username = data["username"] as? String,
				  let message = data["message"] as? String,
				  let isRead = data["isRead"] as? Bool,
				  let createdAt = data["createdAt"] as? Timestamp else {
				continue
			}
			
			let createdAtDate = createdAt.dateValue()
			
			// Check if notification is older than 24 hours
			if createdAtDate < twentyFourHoursAgo {
				notificationsToDelete.append(doc.documentID)
				continue
			}
			
			// Parse joinedUsers array if present
			var joinedUsers: [[String: Any]]? = nil
			if let joinedUsersData = data["joinedUsers"] as? [[String: Any]] {
				joinedUsers = joinedUsersData
				print("✅ NotificationService: Parsed \(joinedUsersData.count) joined users for notification \(doc.documentID)")
			} else {
				print("⚠️ NotificationService: No joinedUsers data found for notification \(doc.documentID)")
			}
			
			notifications.append(AppNotification(
				id: doc.documentID,
				type: type,
				userId: userId,
				username: username,
				userProfileImageURL: data["userProfileImageURL"] as? String,
				collectionId: data["collectionId"] as? String,
				collectionName: data["collectionName"] as? String,
				message: message,
				isRead: isRead,
				createdAt: createdAtDate,
				status: data["status"] as? String,
				joinedUsers: joinedUsers,
				joinCount: data["joinCount"] as? Int
			))
		}
		
		// Delete old notifications in background
		if !notificationsToDelete.isEmpty {
			Task.detached {
				for notificationId in notificationsToDelete {
					try? await self.deleteNotification(notificationId: notificationId, userId: userId)
				}
				print("✅ NotificationService: Deleted \(notificationsToDelete.count) notifications older than 24 hours")
			}
		}
		
		return notifications
	}
	
	// MARK: - Mark Notification as Read
	func markNotificationAsRead(notificationId: String, userId: String) async throws {
		let db = Firestore.firestore()
		try await db.collection("users")
			.document(userId)
			.collection("notifications")
			.document(notificationId)
			.updateData(["isRead": true])
	}
	
	// MARK: - Delete Notification
	func deleteNotification(notificationId: String, userId: String) async throws {
		let db = Firestore.firestore()
		try await db.collection("users")
			.document(userId)
			.collection("notifications")
			.document(notificationId)
			.delete()
	}
	
	// MARK: - Update Notification Status
	func updateNotificationStatus(notificationId: String, userId: String, status: String) async throws {
		let db = Firestore.firestore()
		try await db.collection("users")
			.document(userId)
			.collection("notifications")
			.document(notificationId)
			.updateData([
				"status": status,
				"isRead": true
			])
	}
	
	// MARK: - Send Batch Join Notification
	func sendBatchJoinNotification(
		collectionId: String,
		collectionName: String,
		joinedUsers: [[String: Any]]
	) async throws {
		// Get collection to find owner and admins
		guard let collection = try await CollectionService.shared.getCollection(collectionId: collectionId) else {
			throw NSError(domain: "NotificationService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Collection not found"])
		}
		
		let db = Firestore.firestore()
		
		// Get all admins (owners array)
		let admins = collection.owners
		
		// Build message with all usernames
		let usernames = joinedUsers.compactMap { $0["username"] as? String }
		let count = joinedUsers.count
		
		let message: String
		if count == 1 {
			message = "\(usernames.first ?? "Someone") joined \(collectionName)"
		} else if count <= 3 {
			message = "\(usernames.joined(separator: ", ")) joined \(collectionName)"
		} else {
			let firstFew = usernames.prefix(3).joined(separator: ", ")
			let remaining = count - 3
			message = "\(firstFew) and \(remaining) other\(remaining == 1 ? "" : "s") joined \(collectionName)"
		}
		
		// Create notification for each admin
		for adminId in admins {
			let notificationData: [String: Any] = [
				"type": "collection_join",
				"userId": joinedUsers.first?["userId"] as? String ?? "", // Use first user as primary
				"username": usernames.first ?? "",
				"userProfileImageURL": joinedUsers.first?["profileImageURL"] as? String ?? "",
				"collectionId": collectionId,
				"collectionName": collectionName,
				"message": message,
				"isRead": false,
				"joinedUsers": joinedUsers, // Store all joined users for display
				"joinCount": count,
				"createdAt": Timestamp()
			]
			
			// Add notification to admin's notifications subcollection
			let notificationRef = db.collection("users")
				.document(adminId)
				.collection("notifications")
				.document()
			
			try await notificationRef.setData(notificationData)
			print("✅ NotificationService: Sent batch join notification to admin: \(adminId) for \(count) users")
		}
		
		// Post notification to trigger UI update
		await MainActor.run {
			NotificationCenter.default.post(
				name: NSNotification.Name("CollectionMembersJoined"),
				object: collectionId,
				userInfo: ["count": count]
			)
		}
	}
	
	// MARK: - Send Collection Invite Notification
	func sendCollectionInviteNotification(
		collectionId: String,
		collectionName: String,
		inviterId: String,
		inviterUsername: String,
		inviterProfileImageURL: String?,
		invitedUserId: String
	) async throws {
		let db = Firestore.firestore()
		
		let notificationData: [String: Any] = [
			"type": "collection_invite",
			"userId": inviterId,
			"username": inviterUsername,
			"userProfileImageURL": inviterProfileImageURL ?? "",
			"collectionId": collectionId,
			"collectionName": collectionName,
			"message": "\(inviterUsername) invited you to join \(collectionName)",
			"isRead": false,
			"status": "pending",
			"createdAt": Timestamp()
		]
		
		// Add notification to invited user's notifications subcollection
		let notificationRef = db.collection("users")
			.document(invitedUserId)
			.collection("notifications")
			.document()
		
		try await notificationRef.setData(notificationData)
		print("✅ NotificationService: Sent collection invite notification to user: \(invitedUserId)")
		
		// Post notification to trigger UI update
		await MainActor.run {
			NotificationCenter.default.post(
				name: NSNotification.Name("CollectionInviteSent"),
				object: collectionId,
				userInfo: ["invitedUserId": invitedUserId]
			)
		}
	}
}

