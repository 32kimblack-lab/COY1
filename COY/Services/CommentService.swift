import Foundation
import FirebaseFirestore
import FirebaseAuth

@MainActor
final class CommentService {
	static let shared = CommentService()
	private init() {}
	
	func loadComments(postId: String) async throws -> [Comment] {
		let db = Firestore.firestore()
		let snapshot = try await db.collection("posts")
			.document(postId)
			.collection("comments")
			.whereField("parentCommentId", isEqualTo: NSNull())
			.order(by: "createdAt", descending: true)
			.getDocuments()
		
		return snapshot.documents.compactMap { doc -> Comment? in
			let data = doc.data()
			return parseComment(from: data, id: doc.documentID, postId: postId)
		}
	}
	
	func loadReplies(postId: String, parentCommentId: String) async throws -> [Comment] {
		let db = Firestore.firestore()
		let snapshot = try await db.collection("posts")
			.document(postId)
			.collection("comments")
			.whereField("parentCommentId", isEqualTo: parentCommentId)
			.order(by: "createdAt", descending: false)
			.getDocuments()
		
		return snapshot.documents.compactMap { doc -> Comment? in
			let data = doc.data()
			return parseComment(from: data, id: doc.documentID, postId: postId)
		}
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

