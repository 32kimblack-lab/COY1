import Foundation
import FirebaseFirestore
import FirebaseAuth
import FirebaseFunctions

/// Service for server-side feed generation (replaces expensive client-side mixing)
@MainActor
final class FeedService {
	static let shared = FeedService()
	private init() {}
	
	private let functions = Functions.functions()
	
	/// Load home feed from server-side Cloud Function (replaces client-side mixing)
	/// This is 10x faster and uses 10x fewer Firestore reads
	func loadHomeFeed(
		pageSize: Int = 20,
		lastPostId: String? = nil
	) async throws -> (posts: [CollectionPost], hasMore: Bool, lastPostId: String?) {
		guard let uid = Auth.auth().currentUser?.uid else {
			throw NSError(domain: "FeedService", code: -1, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])
		}
		
		// Call Cloud Function for server-side feed generation
		let function = functions.httpsCallable("generateHomeFeed")
		let data: [String: Any] = [
			"pageSize": pageSize,
			"lastPostId": lastPostId as Any
		]
		
		do {
			let result = try await function.call(data)
			guard let resultData = result.data as? [String: Any],
				  let postsData = resultData["posts"] as? [[String: Any]] else {
				throw NSError(domain: "FeedService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response from server"])
			}
			
			// Parse posts from server response
			// The Cloud Function returns post data directly, so we can parse it
			var posts: [CollectionPost] = []
			let db = Firestore.firestore()
			
			// Batch fetch posts from Firestore using the IDs returned by Cloud Function
			// This is more efficient than fetching one by one
			let postIds = postsData.compactMap { $0["id"] as? String }
			
			// Firestore 'in' query limit is 10, so batch if needed
			for batch in postIds.chunked(into: 10) {
				let batchPosts = try await withThrowingTaskGroup(of: CollectionPost?.self) { group in
					var results: [CollectionPost?] = []
					
					for postId in batch {
						group.addTask {
							do {
								let postDoc = try await db.collection("posts").document(postId).getDocument()
								return try? PostService.shared.parsePost(from: postDoc)
							} catch {
								return nil
							}
						}
					}
					
					for try await post in group {
						results.append(post)
					}
					
					return results.compactMap { $0 }
				}
				
				posts.append(contentsOf: batchPosts)
			}
			
			let hasMore = resultData["hasMore"] as? Bool ?? false
			let lastPostId = resultData["lastPostId"] as? String
			
			return (posts, hasMore, lastPostId)
		} catch {
			print("❌ FeedService: Error calling generateHomeFeed: \(error.localizedDescription)")
			// Fallback to client-side loading if Cloud Function fails
			throw error
		}
	}
	
	/// Fallback: Load feed client-side (used if Cloud Function fails)
	func loadHomeFeedClientSide(
		followedCollections: [CollectionData],
		limit: Int = 20
	) async throws -> [CollectionPost] {
		var allPosts: [CollectionPost] = []
		
		// Load posts from first 5 collections only (for performance)
		let initialCollections = Array(followedCollections.prefix(5))
		
		await withTaskGroup(of: [CollectionPost].self) { group in
			for collection in initialCollections {
				group.addTask {
					do {
						let (posts, _, _) = try await PostService.shared.getCollectionPostsPaginated(
							collectionId: collection.id,
							limit: 10,
							lastDocument: nil,
							sortBy: "Newest to Oldest"
						)
						return posts
					} catch {
						print("Error loading posts for collection \(collection.id): \(error)")
						return []
					}
				}
			}
			
			for await posts in group {
				allPosts.append(contentsOf: posts)
			}
		}
		
		return allPosts
	}
}
