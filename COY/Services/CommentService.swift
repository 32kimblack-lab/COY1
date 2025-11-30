import Foundation
import FirebaseFirestore
import FirebaseAuth

@MainActor
final class CommentService {
	static let shared = CommentService()
	private init() {}
	
	func loadComments(postId: String) async throws -> [Comment] {
		let db = Firestore.firestore()
		// OPTIMIZATION: Add limit to prevent loading all comments at once
		// Use pagination for posts with many comments
		let snapshot = try await db.collection("posts")
			.document(postId)
			.collection("comments")
			.whereField("parentCommentId", isEqualTo: NSNull())
			.order(by: "createdAt", descending: true)
			.limit(to: 50) // Load first 50 comments, can paginate for more
			.getDocuments()
		
		let comments = snapshot.documents.compactMap { doc -> Comment? in
			let data = doc.data()
			return parseComment(from: data, id: doc.documentID, postId: postId)
		}
		
		// Filter out comments from blocked users (mutual blocking)
		return await filterCommentsFromBlockedUsers(comments)
	}
	
	func loadReplies(postId: String, parentCommentId: String) async throws -> [Comment] {
		let db = Firestore.firestore()
		// OPTIMIZATION: Add limit to prevent loading all replies at once
		let snapshot = try await db.collection("posts")
			.document(postId)
			.collection("comments")
			.whereField("parentCommentId", isEqualTo: parentCommentId)
			.order(by: "createdAt", descending: false)
			.limit(to: 20) // Load first 20 replies, can paginate for more
			.getDocuments()
		
		let replies = snapshot.documents.compactMap { doc -> Comment? in
			let data = doc.data()
			return parseComment(from: data, id: doc.documentID, postId: postId)
		}
		
		// Filter out replies from blocked users (mutual blocking)
		return await filterCommentsFromBlockedUsers(replies)
	}
	
	func addComment(postId: String, text: String, parentCommentId: String? = nil) async throws {
		guard let currentUserId = Auth.auth().currentUser?.uid else {
			throw NSError(domain: "CommentService", code: -1, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])
		}
		
		// Get user info
		guard let user = try await UserService.shared.getUser(userId: currentUserId) else {
			throw NSError(domain: "CommentService", code: -1, userInfo: [NSLocalizedDescriptionKey: "User not found"])
		}
		
		let db = Firestore.firestore()
		let commentRef = db.collection("posts").document(postId).collection("comments").document()
		
		var commentData: [String: Any] = [
			"text": text,
			"authorId": currentUserId,
			"userId": currentUserId,
			"username": user.username,
			"name": user.name,
			"authorName": user.name,
			"createdAt": Timestamp(),
			"replyCount": 0
		]
		
		if let profileImageURL = user.profileImageURL {
			commentData["authorImageURL"] = profileImageURL
			commentData["profileImageURL"] = profileImageURL
		}
		
		if let parentCommentId = parentCommentId {
			commentData["parentCommentId"] = parentCommentId
			
			// Increment reply count on parent comment
			let parentRef = db.collection("posts").document(postId).collection("comments").document(parentCommentId)
			try await parentRef.updateData([
				"replyCount": FieldValue.increment(Int64(1))
			])
		}
		
		try await commentRef.setData(commentData)
		
		// OPTIMIZATION: Update commentCount in post document for efficient counting
		// This prevents expensive "fetch all comments" operations
		let postRef = db.collection("posts").document(postId)
		try await postRef.updateData([
			"commentCount": FieldValue.increment(Int64(1))
		])
		
		// Send comment/reply notification
		Task {
			do {
				// Get post data to find owner
				let db = Firestore.firestore()
				let postDoc = try await db.collection("posts").document(postId).getDocument()
				guard let postData = postDoc.data(),
					  let postOwnerId = postData["authorId"] as? String else {
					return
				}
				
				// Get post thumbnail
				let mediaItems = postData["mediaItems"] as? [[String: Any]] ?? []
				let firstMedia = mediaItems.first
				let thumbnailURL = firstMedia?["thumbnailURL"] as? String ?? firstMedia?["imageURL"] as? String
				
				if let parentCommentId = parentCommentId {
					// This is a reply - notify the original commenter
					let parentCommentDoc = try await db.collection("posts")
						.document(postId)
						.collection("comments")
						.document(parentCommentId)
						.getDocument()
					
					if let parentData = parentCommentDoc.data(),
					   let originalCommentUserId = parentData["authorId"] as? String ?? parentData["userId"] as? String {
						try await NotificationService.shared.sendCommentReplyNotification(
							postId: postId,
							commentId: parentCommentId,
							replyId: commentRef.documentID,
							replyUserId: currentUserId,
							replyUsername: user.username,
							replyProfileImageURL: user.profileImageURL,
							replyText: text,
							postThumbnailURL: thumbnailURL,
							originalCommentUserId: originalCommentUserId
						)
					}
				} else {
					// This is a comment - notify the post owner
					try await NotificationService.shared.sendCommentNotification(
						postId: postId,
						commentId: commentRef.documentID,
						commentUserId: currentUserId,
						commentUsername: user.username,
						commentProfileImageURL: user.profileImageURL,
						commentText: text,
						postThumbnailURL: thumbnailURL,
						postOwnerId: postOwnerId
					)
				}
			} catch {
				print("❌ Error sending comment notification: \(error)")
			}
		}
		
		// Post notification
		NotificationCenter.default.post(
			name: NSNotification.Name("CommentAdded"),
			object: postId
		)
	}
	
	func deleteComment(postId: String, commentId: String, parentCommentId: String?) async throws {
		let db = Firestore.firestore()
		let commentRef = db.collection("posts").document(postId).collection("comments").document(commentId)
		
		// Get comment to check reply count
		let commentDoc = try await commentRef.getDocument()
		if let data = commentDoc.data(),
		   let replyCount = data["replyCount"] as? Int, replyCount > 0 {
			// Comment has replies - soft delete by clearing text
			try await commentRef.updateData([
				"text": "[deleted]",
				"isDeleted": true
			])
		} else {
			// No replies - hard delete
			try await commentRef.delete()
			
			// OPTIMIZATION: Decrement commentCount in post document
			let postRef = db.collection("posts").document(postId)
			try await postRef.updateData([
				"commentCount": FieldValue.increment(Int64(-1))
			])
			
			// Decrement reply count on parent if this was a reply
			if let parentCommentId = parentCommentId {
				let parentRef = db.collection("posts").document(postId).collection("comments").document(parentCommentId)
				try await parentRef.updateData([
					"replyCount": FieldValue.increment(Int64(-1))
				])
			}
		}
		
		// Post notification
		NotificationCenter.default.post(
			name: NSNotification.Name("CommentDeleted"),
			object: postId
		)
	}
	
	/// Filter out comments from blocked users or where author has blocked current user (mutual blocking)
	@MainActor
	private func filterCommentsFromBlockedUsers(_ comments: [Comment]) async -> [Comment] {
		guard let currentUserId = Auth.auth().currentUser?.uid else {
			return comments
		}
		
		do {
			try await CYServiceManager.shared.loadCurrentUser()
			let blockedUserIds = Set(CYServiceManager.shared.getBlockedUsers())
			
			// Get unique author IDs to check
			let authorIds = Set(comments.map { $0.userId })
			
			// Batch fetch author data to check if they've blocked current user
			var authorsWhoBlockedCurrentUser: Set<String> = []
			await withTaskGroup(of: (String, Bool).self) { group in
				for authorId in authorIds {
					group.addTask {
						do {
							let db = Firestore.firestore()
							let authorDoc = try await db.collection("users").document(authorId).getDocument()
							if let data = authorDoc.data(),
							   let authorBlockedUsers = data["blockedUsers"] as? [String],
							   authorBlockedUsers.contains(currentUserId) {
								return (authorId, true)
							}
						} catch {
							print("Error checking if comment author blocked current user: \(error.localizedDescription)")
						}
						return (authorId, false)
					}
				}
				
				for await (authorId, isBlocked) in group {
					if isBlocked {
						authorsWhoBlockedCurrentUser.insert(authorId)
					}
				}
			}
			
			return comments.filter { comment in
				// Exclude if current user has blocked the author
				if blockedUserIds.contains(comment.userId) {
					return false
				}
				// Exclude if author has blocked current user (mutual blocking)
				if authorsWhoBlockedCurrentUser.contains(comment.userId) {
					return false
				}
				return true
			}
		} catch {
			print("Error filtering comments from blocked users: \(error.localizedDescription)")
			return comments
		}
	}
	
	private func parseComment(from data: [String: Any], id: String, postId: String) -> Comment? {
		guard let text = data["text"] as? String,
			  let userId = data["authorId"] as? String ?? data["userId"] as? String,
			  let username = data["username"] as? String ?? data["authorName"] as? String,
			  let name = data["name"] as? String ?? data["authorName"] as? String,
			  let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() else {
			return nil
		}
		
		let profileImageURL = data["authorImageURL"] as? String ?? data["profileImageURL"] as? String
		let parentCommentId = data["parentCommentId"] as? String
		let replyCount = data["replyCount"] as? Int ?? 0
		
		return Comment(
			id: id,
			postId: postId,
			userId: userId,
			username: username,
			name: name,
			profileImageURL: profileImageURL,
			text: text,
			createdAt: createdAt,
			parentCommentId: parentCommentId,
			replyCount: replyCount
		)
	}
}

