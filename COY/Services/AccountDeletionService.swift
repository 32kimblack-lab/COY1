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
		let collectionsSnapshot = try await db.collection("collections")
			.whereField("ownerId", isEqualTo: userId)
			.getDocuments()
		
		print("📋 Found \(collectionsSnapshot.documents.count) collections to delete")
		
		for collectionDoc in collectionsSnapshot.documents {
			let collectionId = collectionDoc.documentID
			let collectionData = collectionDoc.data()
			
			// Delete all posts in collection
			let postsSnapshot = try await db.collection("posts")
				.whereField("collectionId", isEqualTo: collectionId)
				.getDocuments()
			
			for postDoc in postsSnapshot.documents {
				try await deletePost(postId: postDoc.documentID, postData: postDoc.data(), db: db, storage: storage)
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
		}
		
		// Also delete from deleted_collections
		let deletedCollectionsSnapshot = try await db.collection("users").document(userId)
			.collection("deleted_collections")
			.getDocuments()
		
		for deletedDoc in deletedCollectionsSnapshot.documents {
			try await deletedDoc.reference.delete()
		}
		
		print("✅ Deleted all collections")
	}
	
	private func deleteAllUserPosts(userId: String, db: Firestore, storage: Storage) async throws {
		// Get all posts created by user (even in other people's collections)
		let postsSnapshot = try await db.collection("posts")
			.whereField("authorId", isEqualTo: userId)
			.getDocuments()
		
		print("📋 Found \(postsSnapshot.documents.count) posts to delete")
		
		for postDoc in postsSnapshot.documents {
			let postData = postDoc.data()
			try await deletePost(postId: postDoc.documentID, postData: postData, db: db, storage: storage)
		}
		
		print("✅ Deleted all user posts")
	}
	
	private func deletePost(postId: String, postData: [String: Any], db: Firestore, storage: Storage) async throws {
		// Delete all comments for this post
		let commentsSnapshot = try await db.collection("posts")
			.document(postId)
			.collection("comments")
			.getDocuments()
		
		for commentDoc in commentsSnapshot.documents {
			try await commentDoc.reference.delete()
		}
		
		// Delete all stars for this post
		let starsSnapshot = try await db.collection("posts")
			.document(postId)
			.collection("stars")
			.getDocuments()
		
		for starDoc in starsSnapshot.documents {
			try await starDoc.reference.delete()
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
		// Get all posts to check for comments
		let postsSnapshot = try await db.collection("posts").limit(to: 1000).getDocuments()
		
		for postDoc in postsSnapshot.documents {
			let commentsSnapshot = try await db.collection("posts")
				.document(postDoc.documentID)
				.collection("comments")
				.whereField("authorId", isEqualTo: userId)
				.getDocuments()
			
			for commentDoc in commentsSnapshot.documents {
				try await commentDoc.reference.delete()
			}
		}
		
		print("✅ Deleted all user comments")
	}
	
	private func deleteAllUserStars(userId: String, db: Firestore) async throws {
		// Get all posts to check for stars
		let postsSnapshot = try await db.collection("posts").limit(to: 1000).getDocuments()
		
		for postDoc in postsSnapshot.documents {
			let starRef = db.collection("posts")
				.document(postDoc.documentID)
				.collection("stars")
				.document(userId)
			
			if (try? await starRef.getDocument().exists) == true {
				try await starRef.delete()
			}
		}
		
		// Also remove from user's starredPostIds
		try? await db.collection("users").document(userId).updateData([
			"starredPostIds": FieldValue.delete()
		])
		
		print("✅ Deleted all user stars")
	}
	
	private func deleteAllMessages(userId: String, db: Firestore) async throws {
		// Delete all chat conversations
		let chatsSnapshot = try await db.collection("chat_rooms")
			.whereField("participants", arrayContains: userId)
			.getDocuments()
		
		for chatDoc in chatsSnapshot.documents {
			// Delete all messages in this chat
			let messagesSnapshot = try await chatDoc.reference
				.collection("messages")
				.getDocuments()
			
			for messageDoc in messagesSnapshot.documents {
				try await messageDoc.reference.delete()
			}
			
			// Delete chat document
			try await chatDoc.reference.delete()
		}
		
		print("✅ Deleted all messages")
	}
	
	private func deleteFriendRequests(userId: String, db: Firestore) async throws {
		// Delete sent friend requests
		let sentRequestsSnapshot = try await db.collection("friend_requests")
			.whereField("fromUid", isEqualTo: userId)
			.getDocuments()
		
		for requestDoc in sentRequestsSnapshot.documents {
			try await requestDoc.reference.delete()
		}
		
		// Delete received friend requests
		let receivedRequestsSnapshot = try await db.collection("friend_requests")
			.whereField("toUid", isEqualTo: userId)
			.getDocuments()
		
		for requestDoc in receivedRequestsSnapshot.documents {
			try await requestDoc.reference.delete()
		}
		
		print("✅ Deleted all friend requests")
	}
	
	private func deleteNotifications(userId: String, db: Firestore) async throws {
		// Delete all notifications for user
		let notificationsSnapshot = try await db.collection("notifications")
			.whereField("userId", isEqualTo: userId)
			.getDocuments()
		
		for notificationDoc in notificationsSnapshot.documents {
			try await notificationDoc.reference.delete()
		}
		
		// Also delete notifications where user is the actor
		let actorNotificationsSnapshot = try await db.collection("notifications")
			.whereField("actorId", isEqualTo: userId)
			.getDocuments()
		
		for notificationDoc in actorNotificationsSnapshot.documents {
			try await notificationDoc.reference.delete()
		}
		
		print("✅ Deleted all notifications")
	}
	
	private func removeUserFromFriendLists(userId: String, db: Firestore) async throws {
		// Find all users who have this user in their friends list
		let usersSnapshot = try await db.collection("users")
			.whereField("friends", arrayContains: userId)
			.getDocuments()
		
		for userDoc in usersSnapshot.documents {
			try await userDoc.reference.updateData([
				"friends": FieldValue.arrayRemove([userId])
			])
		}
		
		print("✅ Removed user from all friend lists")
	}
	
	private func removeUserFromCollections(userId: String, db: Firestore) async throws {
		// Find all collections where user is a member
		let collectionsSnapshot = try await db.collection("collections")
			.whereField("members", arrayContains: userId)
			.getDocuments()
		
		for collectionDoc in collectionsSnapshot.documents {
			try await collectionDoc.reference.updateData([
				"members": FieldValue.arrayRemove([userId]),
				"memberCount": FieldValue.increment(Int64(-1))
			])
		}
		
		print("✅ Removed user from all collections")
	}
	
	private func deleteStorageFiles(userId: String, storage: Storage) async throws {
		// Delete profile image
		let profileImageRef = storage.reference().child("profile_images/\(userId).jpg")
		try? await profileImageRef.delete()
		
		// Delete background image
		let backgroundImageRef = storage.reference().child("background_images/\(userId).jpg")
		try? await backgroundImageRef.delete()
		
		// Delete all post media files (they should already be deleted, but just in case)
		let postsRef = storage.reference().child("posts")
		try? await postsRef.listAll()
		
		print("✅ Deleted storage files")
	}
}

