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
		var type: String // "collection_request", "follow", "collection_join", "collection_star", "collection_post", "comment", "comment_reply", etc.
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
		var postId: String? // For update notifications (star, comment, reply)
		var postThumbnailURL: String? // For update notifications
		var commentText: String? // For comment/reply notifications
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
		
		// Get all recipients: owner + all admins (excluding requester)
		var recipients = Set<String>()
		
		// Add owner
		if collection.ownerId != currentUserId {
			recipients.insert(collection.ownerId)
		}
		
		// Add all admins (from owners array, excluding owner if they're in there)
		for adminId in collection.owners {
			// Skip if requester is the admin, or if it's the owner (already added above)
			if adminId != currentUserId && adminId != collection.ownerId {
				recipients.insert(adminId)
			}
		}
		
		// Create or update notification for each recipient (owner + admins)
		// Use retry logic for all Firestore operations
		for recipientId in recipients {
			
			let notificationsRef = db.collection("users")
				.document(recipientId)
				.collection("notifications")
			
			// First, delete ALL existing pending request notifications from this user for this collection
			// This ensures we never have duplicates, even if there are multiple for some reason
			let deleteQuery = notificationsRef
				.whereField("type", isEqualTo: "collection_request")
				.whereField("userId", isEqualTo: currentUserId)
				.whereField("collectionId", isEqualTo: collectionId)
				.whereField("status", isEqualTo: "pending")
			
			// Use retry logic for delete query
			let deleteSnapshot = try? await FirebaseRetryManager.shared.executeWithRetry(
				operation: {
					try await deleteQuery.getDocuments()
				},
				operationName: "Get notifications to delete"
			)
			
			// Delete all existing pending notifications (with retry)
			for doc in deleteSnapshot?.documents ?? [] {
				try await FirebaseRetryManager.shared.executeWithRetry(
					operation: {
				try await doc.reference.delete()
					},
					operationName: "Delete notification"
				)
				print("🗑️ NotificationService: Deleted existing collection request notification for recipient: \(recipientId)")
			}
			
			// Now create a fresh notification (with retry)
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
			
			let notificationRef = notificationsRef.document()
			try await FirebaseRetryManager.shared.executeWithRetry(
				operation: {
			try await notificationRef.setData(notificationData)
				},
				operationName: "Create notification"
			)
			let recipientType = recipientId == collection.ownerId ? "owner" : "admin"
			print("✅ NotificationService: Sent collection request notification to \(recipientType): \(recipientId)")
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
			
			// Find and delete ALL request notifications from this user for this collection
			// (not just pending ones, to handle any edge cases)
			let query = notificationsRef
				.whereField("type", isEqualTo: "collection_request")
				.whereField("userId", isEqualTo: currentUserId)
				.whereField("collectionId", isEqualTo: collectionId)
			
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
			
			// Parse joinedUsers array if present (only for collection_join notifications)
			var joinedUsers: [[String: Any]]? = nil
			if type == "collection_join", let joinedUsersData = data["joinedUsers"] as? [[String: Any]] {
				joinedUsers = joinedUsersData
				print("✅ NotificationService: Parsed \(joinedUsersData.count) joined users for notification \(doc.documentID)")
			}
			// Note: Most notification types don't have joinedUsers, so we don't log warnings for them
			
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
				joinCount: data["joinCount"] as? Int,
				postId: data["postId"] as? String,
				postThumbnailURL: data["postThumbnailURL"] as? String,
				commentText: data["commentText"] as? String
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
		
		// Get all recipients: owner + all admins
		var recipients = Set<String>()
		
		// Add owner
		recipients.insert(collection.ownerId)
		
		// Add all admins (from owners array, excluding owner if they're in there)
		for adminId in collection.owners {
			if adminId != collection.ownerId {
				recipients.insert(adminId)
			}
		}
		
		// Build message with all usernames
		let usernames = joinedUsers.compactMap { $0["username"] as? String }
		let count = joinedUsers.count
		
		let message: String
		if count == 1 {
			message = "\(usernames.first ?? "Someone") joined \(collectionName)"
		} else if count <= 6 {
			// Show all usernames when 6 or fewer people join
			message = "\(usernames.joined(separator: ", ")) joined \(collectionName)"
		} else {
			// If more than 6, show first few and remaining count
			let firstFew = usernames.prefix(3).joined(separator: ", ")
			let remaining = count - 3
			message = "\(firstFew) and \(remaining) other\(remaining == 1 ? "" : "s") joined \(collectionName)"
		}
		
		// Create notification for each recipient (owner + admins)
		for recipientId in recipients {
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
			
			// Add notification to recipient's notifications subcollection
			let notificationRef = db.collection("users")
				.document(recipientId)
				.collection("notifications")
				.document()
			
			try await notificationRef.setData(notificationData)
			let recipientType = recipientId == collection.ownerId ? "owner" : "admin"
			print("✅ NotificationService: Sent batch join notification to \(recipientType): \(recipientId) for \(count) users")
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
	
	// MARK: - Send Collection Star Update Notification
	func sendCollectionStarNotification(
		postId: String,
		collectionId: String,
		collectionName: String,
		starUserId: String,
		starUsername: String,
		starProfileImageURL: String?,
		postThumbnailURL: String?,
		postOwnerId: String
	) async throws {
		// Don't notify if user starred their own post
		guard starUserId != postOwnerId else { return }
		
		let db = Firestore.firestore()
		
		let notificationData: [String: Any] = [
			"type": "collection_star",
			"userId": starUserId,
			"username": starUsername,
			"userProfileImageURL": starProfileImageURL ?? "",
			"collectionId": collectionId,
			"collectionName": collectionName,
			"message": "New star in collection \"\(collectionName)\"",
			"isRead": false,
			"postId": postId,
			"postThumbnailURL": postThumbnailURL ?? "",
			"createdAt": Timestamp()
		]
		
		// Add notification to post owner's notifications subcollection
		let notificationRef = db.collection("users")
			.document(postOwnerId)
			.collection("notifications")
			.document()
		
		try await notificationRef.setData(notificationData)
		print("✅ NotificationService: Sent collection star notification to user: \(postOwnerId)")
		
		// Post notification to trigger UI update
		await MainActor.run {
			NotificationCenter.default.post(
				name: NSNotification.Name("CollectionStarNotification"),
				object: postId,
				userInfo: ["starUserId": starUserId]
			)
		}
	}
	
	// MARK: - Send Collection Post Update Notification
	func sendCollectionPostNotification(
		collectionId: String,
		collectionName: String,
		postAuthorId: String,
		postAuthorUsername: String,
		postAuthorProfileImageURL: String?,
		postId: String,
		postThumbnailURL: String?,
		collectionMemberIds: [String]
	) async throws {
		// Get collection to check type and get owner/admins
		guard let collection = try await CollectionService.shared.getCollection(collectionId: collectionId) else {
			return
		}
		
		// Only send notifications for "Request" and "Invite" type collections
		guard collection.type == "Request" || collection.type == "Invite" else {
			print("⏭️ NotificationService: Skipping collection post notification - collection type is '\(collection.type)', only 'Request' and 'Invite' collections receive notifications")
			return
		}
		
		let db = Firestore.firestore()
		
		// Get all recipients: owner + admins + members (excluding post author)
		var recipients = Set<String>()
		
		// Add owner
		if collection.ownerId != postAuthorId {
			recipients.insert(collection.ownerId)
		}
		
		// Add all admins (from owners array, excluding owner if they're in there)
		for adminId in collection.owners {
			if adminId != postAuthorId && adminId != collection.ownerId {
				recipients.insert(adminId)
			}
		}
		
		// Add all members (excluding post author)
		for memberId in collectionMemberIds {
			if memberId != postAuthorId {
				recipients.insert(memberId)
			}
		}
		
		// Send notification to all recipients
		for recipientId in recipients {
			let notificationData: [String: Any] = [
				"type": "collection_post",
				"userId": postAuthorId,
				"username": postAuthorUsername,
				"userProfileImageURL": postAuthorProfileImageURL ?? "",
				"collectionId": collectionId,
				"collectionName": collectionName,
				"message": "\(postAuthorUsername) has posted in the collection\n\"\(collectionName)\"",
				"isRead": false,
				"postId": postId,
				"postThumbnailURL": postThumbnailURL ?? "",
				"createdAt": Timestamp()
			]
			
			// Add notification to recipient's notifications subcollection
			let notificationRef = db.collection("users")
				.document(recipientId)
				.collection("notifications")
				.document()
			
			try await notificationRef.setData(notificationData)
			let recipientType = recipientId == collection.ownerId ? "owner" : (collection.owners.contains(recipientId) ? "admin" : "member")
			print("✅ NotificationService: Sent collection post notification to \(recipientType): \(recipientId)")
		}
		
		// Post notification to trigger UI update
		await MainActor.run {
			NotificationCenter.default.post(
				name: NSNotification.Name("CollectionPostNotification"),
				object: collectionId,
				userInfo: ["postAuthorId": postAuthorId, "postId": postId]
			)
		}
	}
	
	// MARK: - Send Comment Update Notification
	func sendCommentNotification(
		postId: String,
		commentId: String,
		commentUserId: String,
		commentUsername: String,
		commentProfileImageURL: String?,
		commentText: String,
		postThumbnailURL: String?,
		postOwnerId: String
	) async throws {
		// Don't notify if user commented on their own post
		guard commentUserId != postOwnerId else { return }
		
		let db = Firestore.firestore()
		
		let notificationData: [String: Any] = [
			"type": "comment",
			"userId": commentUserId,
			"username": commentUsername,
			"userProfileImageURL": commentProfileImageURL ?? "",
			"message": "\(commentUsername)",
			"isRead": false,
			"postId": postId,
			"postThumbnailURL": postThumbnailURL ?? "",
			"commentText": commentText,
			"createdAt": Timestamp()
		]
		
		// Add notification to post owner's notifications subcollection
		let notificationRef = db.collection("users")
			.document(postOwnerId)
			.collection("notifications")
			.document()
		
		try await notificationRef.setData(notificationData)
		print("✅ NotificationService: Sent comment notification to user: \(postOwnerId)")
		
		// Post notification to trigger UI update
		await MainActor.run {
			NotificationCenter.default.post(
				name: NSNotification.Name("CommentNotification"),
				object: postId,
				userInfo: ["commentUserId": commentUserId, "commentId": commentId]
			)
		}
	}
	
	// MARK: - Send Comment Reply Update Notification
	func sendCommentReplyNotification(
		postId: String,
		commentId: String,
		replyId: String,
		replyUserId: String,
		replyUsername: String,
		replyProfileImageURL: String?,
		replyText: String,
		postThumbnailURL: String?,
		originalCommentUserId: String
	) async throws {
		// Don't notify if user replied to their own comment
		guard replyUserId != originalCommentUserId else { return }
		
		let db = Firestore.firestore()
		
		let notificationData: [String: Any] = [
			"type": "comment_reply",
			"userId": replyUserId,
			"username": replyUsername,
			"userProfileImageURL": replyProfileImageURL ?? "",
			"message": "\(replyUsername)",
			"isRead": false,
			"postId": postId,
			"postThumbnailURL": postThumbnailURL ?? "",
			"commentText": replyText,
			"createdAt": Timestamp()
		]
		
		// Add notification to original commenter's notifications subcollection
		let notificationRef = db.collection("users")
			.document(originalCommentUserId)
			.collection("notifications")
			.document()
		
		try await notificationRef.setData(notificationData)
		print("✅ NotificationService: Sent comment reply notification to user: \(originalCommentUserId)")
		
		// Post notification to trigger UI update
		await MainActor.run {
			NotificationCenter.default.post(
				name: NSNotification.Name("CommentReplyNotification"),
				object: postId,
				userInfo: ["replyUserId": replyUserId, "replyId": replyId]
			)
		}
	}
}

