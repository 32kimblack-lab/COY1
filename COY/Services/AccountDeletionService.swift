import Foundation
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage

@MainActor
final class AccountDeletionService {
	static let shared = AccountDeletionService()
	private init() {}
	
	/// Permanently delete user account and all associated data
	func permanentlyDeleteAccount(password: String) async throws {
		guard let user = Auth.auth().currentUser else {
			throw NSError(domain: "AccountDeletionService", code: -1, userInfo: [NSLocalizedDescriptionKey: "No user is currently signed in"])
		}
		
		guard let email = user.email else {
			throw NSError(domain: "AccountDeletionService", code: -2, userInfo: [NSLocalizedDescriptionKey: "User email not found"])
		}
		
		print("🗑️ AccountDeletionService: Starting account deletion for user: \(user.uid)")
		
		// Step 1: Re-authenticate user with password
		print("🔐 AccountDeletionService: Re-authenticating user...")
		let credential = EmailAuthProvider.credential(withEmail: email, password: password)
		try await user.reauthenticate(with: credential)
		print("✅ AccountDeletionService: User re-authenticated successfully")
		
		let userId = user.uid
		let db = Firestore.firestore()
		let storage = Storage.storage()
		
		// Step 2: Delete all collections and their posts
		print("🗑️ AccountDeletionService: Deleting all collections...")
		try await deleteAllCollections(userId: userId, db: db, storage: storage)
		
		// Step 3: Delete all posts created by user (even in other people's collections)
		print("🗑️ AccountDeletionService: Deleting all posts created by user...")
		try await deleteAllUserPosts(userId: userId, db: db, storage: storage)
		
		// Step 4: Delete all comments made by user
		print("🗑️ AccountDeletionService: Deleting all comments...")
		try await deleteAllUserComments(userId: userId, db: db)
		
		// Step 5: Delete all stars by user
		print("🗑️ AccountDeletionService: Deleting all stars...")
		try await deleteAllUserStars(userId: userId, db: db)
		
		// Step 6: Delete all messages
		print("🗑️ AccountDeletionService: Deleting all messages...")
		try await deleteAllMessages(userId: userId, db: db)
		
		// Step 7: Delete friend requests
		print("🗑️ AccountDeletionService: Deleting friend requests...")
		try await deleteFriendRequests(userId: userId, db: db)
		
		// Step 8: Delete notifications
		print("🗑️ AccountDeletionService: Deleting notifications...")
		try await deleteNotifications(userId: userId, db: db)
		
		// Step 9: Delete user from other users' friend lists
		print("🗑️ AccountDeletionService: Removing user from other users' friend lists...")
		try await removeUserFromFriendLists(userId: userId, db: db)
		
		// Step 10: Delete user from collections they're members of
		print("🗑️ AccountDeletionService: Removing user from collections...")
		try await removeUserFromCollections(userId: userId, db: db)
		
		// Step 11: Delete storage files (profile image, background image, post media)
		print("🗑️ AccountDeletionService: Deleting storage files...")
		try await deleteStorageFiles(userId: userId, storage: storage)
		
		// Step 12: Delete user document from Firestore
		print("🗑️ AccountDeletionService: Deleting user document...")
		try await db.collection("users").document(userId).delete()
		print("✅ AccountDeletionService: User document deleted")
		
		// Step 13: Delete Firebase Auth account
		print("🗑️ AccountDeletionService: Deleting Firebase Auth account...")
		try await user.delete()
		print("✅ AccountDeletionService: Firebase Auth account deleted")
		
		print("✅ AccountDeletionService: Account permanently deleted successfully")
	}
	
	// MARK: - Private Helper Methods
	
	private func deleteAllCollections(userId: String, db: Firestore, storage: Storage) async throws {
		// Get all collections owned by user
		// CRITICAL FIX: Add limit and pagination for scalability
		var lastDocument: DocumentSnapshot? = nil
		var hasMore = true
		var totalDeleted = 0
		
		while hasMore {
			var query = db.collection("collections")
			.whereField("ownerId", isEqualTo: userId)
				.limit(to: 100) // Process 100 at a time
			
			if let lastDoc = lastDocument {
				query = query.start(afterDocument: lastDoc)
			}
			
			let collectionsSnapshot = try await query.getDocuments()
			print("📋 Processing batch of \(collectionsSnapshot.documents.count) collections (total deleted: \(totalDeleted))")
			
			if collectionsSnapshot.documents.isEmpty {
				hasMore = false
				break
			}
		
		for collectionDoc in collectionsSnapshot.documents {
			let collectionId = collectionDoc.documentID
			let collectionData = collectionDoc.data()
			
				// Delete all posts in collection (with pagination)
				var postLastDoc: DocumentSnapshot? = nil
				var hasMorePosts = true
				
				while hasMorePosts {
					var postQuery = db.collection("posts")
				.whereField("collectionId", isEqualTo: collectionId)
						.limit(to: 100) // Process 100 posts at a time
					
					if let lastPostDoc = postLastDoc {
						postQuery = postQuery.start(afterDocument: lastPostDoc)
					}
					
					let postsSnapshot = try await postQuery.getDocuments()
			
			for postDoc in postsSnapshot.documents {
				try await deletePost(postId: postDoc.documentID, postData: postDoc.data(), db: db, storage: storage)
					}
					
					hasMorePosts = postsSnapshot.documents.count == 100
					postLastDoc = postsSnapshot.documents.last
			}
			
			// Delete collection image
			if let imageURL = collectionData["imageURL"] as? String, !imageURL.isEmpty {
				if let url = URL(string: imageURL) {
					let imageRef = storage.reference(forURL: url.absoluteString)
					try? await imageRef.delete()
				}
			}
			
			// Delete collection document
			try await collectionDoc.reference.delete()
				totalDeleted += 1
			}
			
			hasMore = collectionsSnapshot.documents.count == 100
			lastDocument = collectionsSnapshot.documents.last
		}
		
		// Also delete from deleted_collections (with pagination)
		var deletedLastDoc: DocumentSnapshot? = nil
		var hasMoreDeleted = true
		
		while hasMoreDeleted {
			var deletedQuery = db.collection("users").document(userId)
			.collection("deleted_collections")
				.limit(to: 100)
			
			if let lastDoc = deletedLastDoc {
				deletedQuery = deletedQuery.start(afterDocument: lastDoc)
			}
			
			let deletedCollectionsSnapshot = try await deletedQuery.getDocuments()
		
		for deletedDoc in deletedCollectionsSnapshot.documents {
			try await deletedDoc.reference.delete()
		}
		
			hasMoreDeleted = deletedCollectionsSnapshot.documents.count == 100
			deletedLastDoc = deletedCollectionsSnapshot.documents.last
		}
		
		print("✅ Deleted all collections (total: \(totalDeleted))")
	}
	
	private func deleteAllUserPosts(userId: String, db: Firestore, storage: Storage) async throws {
		// Get all posts created by user (even in other people's collections)
		// CRITICAL FIX: Add pagination for scalability
		var lastDocument: DocumentSnapshot? = nil
		var hasMore = true
		var totalDeleted = 0
		
		while hasMore {
			var query = db.collection("posts")
			.whereField("authorId", isEqualTo: userId)
				.limit(to: 100) // Process 100 posts at a time
			
			if let lastDoc = lastDocument {
				query = query.start(afterDocument: lastDoc)
			}
			
			let postsSnapshot = try await query.getDocuments()
			print("📋 Processing batch of \(postsSnapshot.documents.count) posts (total deleted: \(totalDeleted))")
			
			if postsSnapshot.documents.isEmpty {
				hasMore = false
				break
			}
		
		for postDoc in postsSnapshot.documents {
			let postData = postDoc.data()
			try await deletePost(postId: postDoc.documentID, postData: postData, db: db, storage: storage)
				totalDeleted += 1
			}
			
			hasMore = postsSnapshot.documents.count == 100
			lastDocument = postsSnapshot.documents.last
		}
		
		print("✅ Deleted all user posts (total: \(totalDeleted))")
	}
	
	private func deletePost(postId: String, postData: [String: Any], db: Firestore, storage: Storage) async throws {
		// Delete all comments for this post (with pagination)
		var commentLastDoc: DocumentSnapshot? = nil
		var hasMoreComments = true
		
		while hasMoreComments {
			var commentQuery = db.collection("posts")
			.document(postId)
			.collection("comments")
				.limit(to: 100)
			
			if let lastDoc = commentLastDoc {
				commentQuery = commentQuery.start(afterDocument: lastDoc)
			}
			
			let commentsSnapshot = try await commentQuery.getDocuments()
		
		for commentDoc in commentsSnapshot.documents {
			try await commentDoc.reference.delete()
		}
		
			hasMoreComments = commentsSnapshot.documents.count == 100
			commentLastDoc = commentsSnapshot.documents.last
		}
		
		// Delete all stars for this post (with pagination)
		var starLastDoc: DocumentSnapshot? = nil
		var hasMoreStars = true
		
		while hasMoreStars {
			var starQuery = db.collection("posts")
			.document(postId)
			.collection("stars")
				.limit(to: 100)
			
			if let lastDoc = starLastDoc {
				starQuery = starQuery.start(afterDocument: lastDoc)
			}
			
			let starsSnapshot = try await starQuery.getDocuments()
		
		for starDoc in starsSnapshot.documents {
			try await starDoc.reference.delete()
			}
			
			hasMoreStars = starsSnapshot.documents.count == 100
			starLastDoc = starsSnapshot.documents.last
		}
		
		// Delete media files
		if let mediaItems = postData["mediaItems"] as? [[String: Any]] {
			for mediaItem in mediaItems {
				if let imageURL = mediaItem["imageURL"] as? String, !imageURL.isEmpty {
					if let url = URL(string: imageURL) {
						let imageRef = storage.reference(forURL: url.absoluteString)
						try? await imageRef.delete()
					}
				}
				
				if let thumbnailURL = mediaItem["thumbnailURL"] as? String, !thumbnailURL.isEmpty {
					if let url = URL(string: thumbnailURL) {
						let thumbnailRef = storage.reference(forURL: url.absoluteString)
						try? await thumbnailRef.delete()
					}
				}
				
				if let videoURL = mediaItem["videoURL"] as? String, !videoURL.isEmpty {
					if let url = URL(string: videoURL) {
						let videoRef = storage.reference(forURL: url.absoluteString)
						try? await videoRef.delete()
					}
				}
			}
		}
		
		// Delete post document
		try await db.collection("posts").document(postId).delete()
	}
	
	private func deleteAllUserComments(userId: String, db: Firestore) async throws {
		// CRITICAL FIX: Use pagination instead of loading all posts
		// This is inefficient but necessary for account deletion
		// Better approach: Use a Cloud Function to delete all comments by userId
		var postLastDoc: DocumentSnapshot? = nil
		var hasMorePosts = true
		var totalCommentsDeleted = 0
		
		while hasMorePosts {
			var postQuery = db.collection("posts")
				.limit(to: 100) // Process 100 posts at a time
			
			if let lastDoc = postLastDoc {
				postQuery = postQuery.start(afterDocument: lastDoc)
			}
			
			let postsSnapshot = try await postQuery.getDocuments()
			
			if postsSnapshot.documents.isEmpty {
				hasMorePosts = false
				break
			}
		
		for postDoc in postsSnapshot.documents {
				// Delete comments by this user in this post (with pagination)
				var commentLastDoc: DocumentSnapshot? = nil
				var hasMoreComments = true
				
				while hasMoreComments {
					var commentQuery = db.collection("posts")
				.document(postDoc.documentID)
				.collection("comments")
				.whereField("authorId", isEqualTo: userId)
						.limit(to: 100)
					
					if let lastDoc = commentLastDoc {
						commentQuery = commentQuery.start(afterDocument: lastDoc)
					}
					
					let commentsSnapshot = try await commentQuery.getDocuments()
			
			for commentDoc in commentsSnapshot.documents {
				try await commentDoc.reference.delete()
						totalCommentsDeleted += 1
					}
					
					hasMoreComments = commentsSnapshot.documents.count == 100
					commentLastDoc = commentsSnapshot.documents.last
				}
			}
			
			hasMorePosts = postsSnapshot.documents.count == 100
			postLastDoc = postsSnapshot.documents.last
		}
		
		print("✅ Deleted all user comments (total: \(totalCommentsDeleted))")
	}
	
	private func deleteAllUserStars(userId: String, db: Firestore) async throws {
		// CRITICAL FIX: Use pagination instead of loading all posts
		// Better approach: Use a Cloud Function to delete all stars by userId
		var postLastDoc: DocumentSnapshot? = nil
		var hasMorePosts = true
		var totalStarsDeleted = 0
		
		while hasMorePosts {
			var postQuery = db.collection("posts")
				.limit(to: 100) // Process 100 posts at a time
			
			if let lastDoc = postLastDoc {
				postQuery = postQuery.start(afterDocument: lastDoc)
			}
			
			let postsSnapshot = try await postQuery.getDocuments()
			
			if postsSnapshot.documents.isEmpty {
				hasMorePosts = false
				break
			}
		
		for postDoc in postsSnapshot.documents {
			let starRef = db.collection("posts")
				.document(postDoc.documentID)
				.collection("stars")
				.document(userId)
			
			if (try? await starRef.getDocument().exists) == true {
				try await starRef.delete()
					totalStarsDeleted += 1
				}
			}
			
			hasMorePosts = postsSnapshot.documents.count == 100
			postLastDoc = postsSnapshot.documents.last
		}
		
		// Also remove from user's starredPostIds
		try? await db.collection("users").document(userId).updateData([
			"starredPostIds": FieldValue.delete()
		])
		
		print("✅ Deleted all user stars (total: \(totalStarsDeleted))")
	}
	
	private func deleteAllMessages(userId: String, db: Firestore) async throws {
		// Delete all chat conversations (with pagination)
		var chatLastDoc: DocumentSnapshot? = nil
		var hasMoreChats = true
		var totalDeleted = 0
		
		while hasMoreChats {
			var chatQuery = db.collection("chat_rooms")
			.whereField("participants", arrayContains: userId)
				.limit(to: 100)
			
			if let lastDoc = chatLastDoc {
				chatQuery = chatQuery.start(afterDocument: lastDoc)
			}
			
			let chatsSnapshot = try await chatQuery.getDocuments()
			
			if chatsSnapshot.documents.isEmpty {
				hasMoreChats = false
				break
			}
		
		for chatDoc in chatsSnapshot.documents {
				// Delete all messages in this chat (with pagination)
				var messageLastDoc: DocumentSnapshot? = nil
				var hasMoreMessages = true
				
				while hasMoreMessages {
					var messageQuery = chatDoc.reference
				.collection("messages")
						.limit(to: 100)
					
					if let lastDoc = messageLastDoc {
						messageQuery = messageQuery.start(afterDocument: lastDoc)
					}
					
					let messagesSnapshot = try await messageQuery.getDocuments()
			
			for messageDoc in messagesSnapshot.documents {
				try await messageDoc.reference.delete()
					}
					
					hasMoreMessages = messagesSnapshot.documents.count == 100
					messageLastDoc = messagesSnapshot.documents.last
			}
			
			// Delete chat document
			try await chatDoc.reference.delete()
				totalDeleted += 1
			}
			
			hasMoreChats = chatsSnapshot.documents.count == 100
			chatLastDoc = chatsSnapshot.documents.last
		}
		
		print("✅ Deleted all messages (total chats: \(totalDeleted))")
	}
	
	private func deleteFriendRequests(userId: String, db: Firestore) async throws {
		// Delete sent friend requests (with pagination)
		var sentLastDoc: DocumentSnapshot? = nil
		var hasMoreSent = true
		
		while hasMoreSent {
			var sentQuery = db.collection("friend_requests")
			.whereField("fromUid", isEqualTo: userId)
				.limit(to: 100)
			
			if let lastDoc = sentLastDoc {
				sentQuery = sentQuery.start(afterDocument: lastDoc)
			}
			
			let sentRequestsSnapshot = try await sentQuery.getDocuments()
			
			if sentRequestsSnapshot.documents.isEmpty {
				hasMoreSent = false
				break
			}
		
		for requestDoc in sentRequestsSnapshot.documents {
			try await requestDoc.reference.delete()
		}
		
			hasMoreSent = sentRequestsSnapshot.documents.count == 100
			sentLastDoc = sentRequestsSnapshot.documents.last
		}
		
		// Delete received friend requests (with pagination)
		var receivedLastDoc: DocumentSnapshot? = nil
		var hasMoreReceived = true
		
		while hasMoreReceived {
			var receivedQuery = db.collection("friend_requests")
			.whereField("toUid", isEqualTo: userId)
				.limit(to: 100)
			
			if let lastDoc = receivedLastDoc {
				receivedQuery = receivedQuery.start(afterDocument: lastDoc)
			}
			
			let receivedRequestsSnapshot = try await receivedQuery.getDocuments()
			
			if receivedRequestsSnapshot.documents.isEmpty {
				hasMoreReceived = false
				break
			}
		
		for requestDoc in receivedRequestsSnapshot.documents {
			try await requestDoc.reference.delete()
			}
			
			hasMoreReceived = receivedRequestsSnapshot.documents.count == 100
			receivedLastDoc = receivedRequestsSnapshot.documents.last
		}
		
		print("✅ Deleted all friend requests")
	}
	
	private func deleteNotifications(userId: String, db: Firestore) async throws {
		// Delete all notifications for user (with pagination)
		var notificationLastDoc: DocumentSnapshot? = nil
		var hasMoreNotifications = true
		
		while hasMoreNotifications {
			var notificationQuery = db.collection("notifications")
			.whereField("userId", isEqualTo: userId)
				.limit(to: 100)
			
			if let lastDoc = notificationLastDoc {
				notificationQuery = notificationQuery.start(afterDocument: lastDoc)
			}
			
			let notificationsSnapshot = try await notificationQuery.getDocuments()
			
			if notificationsSnapshot.documents.isEmpty {
				hasMoreNotifications = false
				break
			}
		
		for notificationDoc in notificationsSnapshot.documents {
			try await notificationDoc.reference.delete()
		}
		
			hasMoreNotifications = notificationsSnapshot.documents.count == 100
			notificationLastDoc = notificationsSnapshot.documents.last
		}
		
		// Also delete notifications where user is the actor (with pagination)
		var actorLastDoc: DocumentSnapshot? = nil
		var hasMoreActor = true
		
		while hasMoreActor {
			var actorQuery = db.collection("notifications")
			.whereField("actorId", isEqualTo: userId)
				.limit(to: 100)
			
			if let lastDoc = actorLastDoc {
				actorQuery = actorQuery.start(afterDocument: lastDoc)
			}
			
			let actorNotificationsSnapshot = try await actorQuery.getDocuments()
			
			if actorNotificationsSnapshot.documents.isEmpty {
				hasMoreActor = false
				break
			}
		
		for notificationDoc in actorNotificationsSnapshot.documents {
			try await notificationDoc.reference.delete()
			}
			
			hasMoreActor = actorNotificationsSnapshot.documents.count == 100
			actorLastDoc = actorNotificationsSnapshot.documents.last
		}
		
		print("✅ Deleted all notifications")
	}
	
	private func removeUserFromFriendLists(userId: String, db: Firestore) async throws {
		// Find all users who have this user in their friends list (with pagination)
		var userLastDoc: DocumentSnapshot? = nil
		var hasMore = true
		var totalRemoved = 0
		
		while hasMore {
			var userQuery = db.collection("users")
			.whereField("friends", arrayContains: userId)
				.limit(to: 100)
			
			if let lastDoc = userLastDoc {
				userQuery = userQuery.start(afterDocument: lastDoc)
			}
			
			let usersSnapshot = try await userQuery.getDocuments()
			
			if usersSnapshot.documents.isEmpty {
				hasMore = false
				break
			}
		
		for userDoc in usersSnapshot.documents {
			try await userDoc.reference.updateData([
				"friends": FieldValue.arrayRemove([userId])
			])
				totalRemoved += 1
			}
			
			hasMore = usersSnapshot.documents.count == 100
			userLastDoc = usersSnapshot.documents.last
		}
		
		print("✅ Removed user from all friend lists (total: \(totalRemoved))")
	}
	
	private func removeUserFromCollections(userId: String, db: Firestore) async throws {
		// Find all collections where user is a member (with pagination)
		var collectionLastDoc: DocumentSnapshot? = nil
		var hasMore = true
		var totalRemoved = 0
		
		while hasMore {
			var collectionQuery = db.collection("collections")
			.whereField("members", arrayContains: userId)
				.limit(to: 100)
			
			if let lastDoc = collectionLastDoc {
				collectionQuery = collectionQuery.start(afterDocument: lastDoc)
			}
			
			let collectionsSnapshot = try await collectionQuery.getDocuments()
			
			if collectionsSnapshot.documents.isEmpty {
				hasMore = false
				break
			}
		
		for collectionDoc in collectionsSnapshot.documents {
			try await collectionDoc.reference.updateData([
				"members": FieldValue.arrayRemove([userId]),
				"memberCount": FieldValue.increment(Int64(-1))
			])
				totalRemoved += 1
			}
			
			hasMore = collectionsSnapshot.documents.count == 100
			collectionLastDoc = collectionsSnapshot.documents.last
		}
		
		print("✅ Removed user from all collections (total: \(totalRemoved))")
	}
	
	private func deleteStorageFiles(userId: String, storage: Storage) async throws {
		// Delete profile image
		let profileImageRef = storage.reference().child("profile_images/\(userId).jpg")
		try? await profileImageRef.delete()
		
		// Delete background image
		let backgroundImageRef = storage.reference().child("background_images/\(userId).jpg")
		try? await backgroundImageRef.delete()
		
		// Delete all post media files (they should already be deleted, but just in case)
		// Note: Individual post media files are deleted when posts are deleted
		// This is just a placeholder - no need to list all posts here
		
		print("✅ Deleted storage files")
	}
}

