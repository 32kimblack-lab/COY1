import Foundation
import FirebaseFirestore
import FirebaseAuth

@MainActor
final class EngagementService {
	static let shared = EngagementService()
	private init() {}
	
	// MARK: - Track Post View
	/// Track when a user views a post (increment view count)
	func trackPostView(postId: String) async {
		guard let userId = Auth.auth().currentUser?.uid else { return }
		
		let db = Firestore.firestore()
		let viewsRef = db.collection("posts").document(postId).collection("views").document(userId)
		
		// Check if user already viewed this post (prevent duplicate views)
		do {
			let viewDoc = try await viewsRef.getDocument()
			if viewDoc.exists {
				// User already viewed, don't increment again
				return
			}
			
			// Mark as viewed
			try await viewsRef.setData([
				"userId": userId,
				"viewedAt": Timestamp()
			])
			
			// Increment view count on post
			let postRef = db.collection("posts").document(postId)
			try await postRef.updateData([
				"viewCount": FieldValue.increment(Int64(1))
			])
			
			// Recalculate engagement score
			Task {
				await recalculateEngagementScore(postId: postId)
			}
		} catch {
			print("⚠️ EngagementService: Error tracking post view: \(error)")
		}
	}
	
	// MARK: - Track Post Like (Star)
	/// Track when a user likes/stars a post (increment like count)
	/// Note: likeCount is now maintained by Firebase Function onStarChanged
	/// This function is kept for backward compatibility but the function handles it automatically
	func trackPostLike(postId: String, isLiked: Bool) async {
		// Like count is automatically updated by Firebase Function onStarChanged
		// when a star is added/removed from posts/{postId}/stars/{userId}
		// Engagement score is automatically recalculated by onPostEngagementUpdated
		// So we don't need to do anything here, but keeping the function for API consistency
	}
	
	// MARK: - Track Post Comment
	/// Track when a comment is added (increment comment count)
	func trackPostComment(postId: String, isAdded: Bool) async {
		// Comment count is already updated by CommentService, but we recalculate engagement
		await recalculateEngagementScore(postId: postId)
	}
	
	// MARK: - Calculate Engagement Score
	/// Calculate engagement score based on likes, comments, views, and recency
	/// Formula: (likes * 3 + comments * 5 + views * 0.1) * recency_factor
	/// Recency factor: exponential decay based on post age
	private func recalculateEngagementScore(postId: String) async {
		let db = Firestore.firestore()
		
		do {
			// Get post data
			let postDoc = try await db.collection("posts").document(postId).getDocument()
			guard let data = postDoc.data() else { return }
			
			let likeCount = data["likeCount"] as? Int ?? 0
			let commentCount = data["commentCount"] as? Int ?? 0
			let viewCount = data["viewCount"] as? Int ?? 0
			let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
			
			// Calculate recency factor (exponential decay)
			let now = Date()
			let timeSinceCreation = now.timeIntervalSince(createdAt)
			let hoursSinceCreation = timeSinceCreation / 3600.0
			
			// Recency factor: 1.0 for posts < 1 hour old, decays to ~0.1 for posts 7 days old
			// Using exponential decay with half-life of ~48 hours
			let recencyFactor = exp(-hoursSinceCreation / 48.0)
			
			// Engagement score formula:
			// - Likes: 3 points each (high value interaction)
			// - Comments: 5 points each (highest value interaction)
			// - Views: 0.1 points each (low value, but scales with popularity)
			let rawScore = Double(likeCount * 3 + commentCount * 5) + Double(viewCount) * 0.1
			let engagementScore = rawScore * recencyFactor
			
			// Update post with new engagement score
			try await postDoc.reference.updateData([
				"engagementScore": engagementScore
			])
			
			print("📊 EngagementService: Updated engagement score for post \(postId): \(String(format: "%.2f", engagementScore)) (likes: \(likeCount), comments: \(commentCount), views: \(viewCount), recency: \(String(format: "%.2f", recencyFactor)))")
		} catch {
			print("⚠️ EngagementService: Error calculating engagement score: \(error)")
		}
	}
	
	// MARK: - Batch Recalculate Engagement Scores
	/// Recalculate engagement scores for multiple posts (useful for migration or periodic updates)
	func batchRecalculateEngagementScores(postIds: [String]) async {
		await withTaskGroup(of: Void.self) { group in
			for postId in postIds {
				group.addTask {
					await self.recalculateEngagementScore(postId: postId)
				}
			}
		}
	}
}
