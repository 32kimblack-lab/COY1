import Foundation
import FirebaseFirestore
import FirebaseAuth

@MainActor
class UpdatesService {
	static let shared = UpdatesService()
	private init() {}
	
	private let db = Firestore.firestore()
	
	// MARK: - Fetch All Updates
	func fetchUpdates() async throws -> [UpdateItem] {
		guard let currentUserId = Auth.auth().currentUser?.uid else {
			throw NSError(domain: "UpdatesService", code: -1, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])
		}
		
		print("🔔 UpdatesService: Fetching all updates for user \(currentUserId)")
		
		var allUpdates: [UpdateItem] = []
		
		// Fetch stars (someone starred my post)
		do {
			let starUpdates = try await fetchStarUpdates(userId: currentUserId)
			allUpdates.append(contentsOf: starUpdates)
			print("✅ UpdatesService: Added \(starUpdates.count) star updates")
		} catch {
			print("❌ UpdatesService: Error fetching star updates: \(error.localizedDescription)")
			// Don't fail completely - continue with other updates
		}
		
		// Fetch comments (someone commented on my post)
		do {
			let commentUpdates = try await fetchCommentUpdates(userId: currentUserId)
			allUpdates.append(contentsOf: commentUpdates)
			print("✅ UpdatesService: Added \(commentUpdates.count) comment updates")
		} catch {
			print("❌ UpdatesService: Error fetching comment updates: \(error.localizedDescription)")
			// Don't fail completely - continue with other updates
		}
		
		// Fetch new posts in shared collections
		do {
			let postUpdates = try await fetchNewPostUpdates(userId: currentUserId)
			allUpdates.append(contentsOf: postUpdates)
			print("✅ UpdatesService: Added \(postUpdates.count) new post updates")
		} catch {
			print("❌ UpdatesService: Error fetching new post updates: \(error.localizedDescription)")
			// Don't fail completely - continue with other updates
		}
		
		// Sort by timestamp (newest first)
		allUpdates.sort { $0.timestamp > $1.timestamp }
		
		print("✅ UpdatesService: Total updates fetched: \(allUpdates.count)")
		print("   - Star updates: \(allUpdates.filter { $0.type == .star }.count)")
		print("   - Comment updates: \(allUpdates.filter { $0.type == .comment || $0.type == .reply }.count)")
		print("   - New post updates: \(allUpdates.filter { $0.type == .newPost }.count)")
		return allUpdates
	}
	
	// MARK: - Fetch Star Updates
	private func fetchStarUpdates(userId: String) async throws -> [UpdateItem] {
		var updates: [UpdateItem] = []
		
		print("🔍 UpdatesService: Fetching star updates for user \(userId)")
		
		// Get all posts owned by current user
		// CRITICAL FIX: Add limit to prevent loading thousands of posts
		// Only check recent posts (last 100) for updates to keep it fast
		let postsSnapshot = try await db.collection("posts")
			.whereField("authorId", isEqualTo: userId)
			.order(by: "createdAt", descending: true)
			.limit(to: 100) // Only check last 100 posts for stars/comments
			.getDocuments()
		
		print("✅ UpdatesService: Found \(postsSnapshot.documents.count) posts owned by user \(userId)")
		
		// Also check if user is owner of collections and get posts from those collections
		// This handles cases where posts might be in collections owned by the user
		// CRITICAL FIX: Add limit to prevent loading all collections
		let collectionsSnapshot = try await db.collection("collections")
			.whereField("ownerId", isEqualTo: userId)
			.limit(to: 50) // Limit to 50 collections max
			.getDocuments()
		
		let ownedCollectionIds = Set(collectionsSnapshot.documents.map { $0.documentID })
		print("✅ UpdatesService: User owns \(ownedCollectionIds.count) collections")
		
		// Get all unique post IDs from author-owned posts
		var allPostIds = Set(postsSnapshot.documents.map { $0.documentID })
		
		// Get posts from owned collections as well (with limit)
		if !ownedCollectionIds.isEmpty {
			for collectionId in ownedCollectionIds {
				// CRITICAL FIX: Add limit to prevent loading all posts
				if let collectionPostsSnapshot = try? await db.collection("posts")
					.whereField("collectionId", isEqualTo: collectionId)
					.order(by: "createdAt", descending: true)
					.limit(to: 50) // Only check last 50 posts per collection
					.getDocuments() {
					print("✅ UpdatesService: Found \(collectionPostsSnapshot.documents.count) posts in owned collection \(collectionId)")
					for doc in collectionPostsSnapshot.documents {
						allPostIds.insert(doc.documentID)
					}
				}
			}
		}
		
		print("✅ UpdatesService: Total unique posts to check: \(allPostIds.count)")
		
		// Process all posts - start with author-owned posts
		var allPostsToCheck = postsSnapshot.documents
		
		// Add posts from owned collections that aren't already included (with limit)
		if !ownedCollectionIds.isEmpty {
			for collectionId in ownedCollectionIds {
				// CRITICAL FIX: Add limit to prevent loading all posts
				if let collectionPostsSnapshot = try? await db.collection("posts")
					.whereField("collectionId", isEqualTo: collectionId)
					.order(by: "createdAt", descending: true)
					.limit(to: 50) // Only check last 50 posts per collection
					.getDocuments() {
					for doc in collectionPostsSnapshot.documents {
						// Only add if not already in author-owned posts
						let alreadyIncluded = postsSnapshot.documents.contains { $0.documentID == doc.documentID }
						if !alreadyIncluded {
							allPostsToCheck.append(doc)
						}
					}
				}
			}
		}
		
		print("✅ UpdatesService: Processing \(allPostsToCheck.count) total posts for stars")
		
		for postDoc in allPostsToCheck {
			let postId = postDoc.documentID
			let postData = postDoc.data()
			
			// Get all stars for this post
			let starsSnapshot = try await db.collection("posts")
				.document(postId)
				.collection("stars")
				.order(by: "starredAt", descending: true)
				.limit(to: 50) // Increased limit to get more stars
				.getDocuments()
			
			print("⭐ UpdatesService: Post \(postId) has \(starsSnapshot.documents.count) stars")
			
			for starDoc in starsSnapshot.documents {
				let starData = starDoc.data()
				guard let starUserId = starData["userId"] as? String else {
					print("⚠️ UpdatesService: Star document missing userId for star \(starDoc.documentID)")
					continue
				}
				
				// Don't show own stars
				if starUserId == userId {
					print("⏭️ UpdatesService: Skipping own star from user \(starUserId)")
					continue
				}
				
				print("⭐ UpdatesService: Processing star from user \(starUserId) on post \(postId)")
				
				// Get user info who starred - don't fail silently
				do {
					guard let user = try await UserService.shared.getUser(userId: starUserId) else {
						print("⚠️ UpdatesService: UserService returned nil for user \(starUserId)")
						continue
					}
					
					// Get collection name
					let collectionId = postData["collectionId"] as? String ?? ""
					var collectionName = "Me"
					if !collectionId.isEmpty {
						if let collectionDoc = try? await db.collection("collections").document(collectionId).getDocument(),
						   let collectionData = collectionDoc.data(),
						   let name = collectionData["name"] as? String {
							collectionName = name
						}
					}
					
					// Get post thumbnail
					let mediaItems = postData["mediaItems"] as? [[String: Any]] ?? []
					let firstMedia = mediaItems.first
					let thumbnailURL = firstMedia?["thumbnailURL"] as? String ?? firstMedia?["imageURL"] as? String
					
					let starredAt = (starData["starredAt"] as? Timestamp)?.dateValue() ?? Date()
					
					let update = UpdateItem(
						id: "star_\(postId)_\(starUserId)_\(starDoc.documentID)",
						type: .star,
						userId: starUserId,
						username: user.username,
						profileImageURL: user.profileImageURL,
						text: "New star in collection \"\(collectionName)\"",
						subText: user.username,
						timestamp: starredAt,
						postId: postId,
						collectionId: collectionId.isEmpty ? nil : collectionId,
						thumbnailURL: thumbnailURL
					)
					updates.append(update)
					print("✅ UpdatesService: Added star update for post \(postId) from \(user.username) at \(starredAt)")
				} catch {
					print("❌ UpdatesService: Error fetching user \(starUserId) for star: \(error.localizedDescription)")
					// Continue processing other stars even if one fails
					continue
				}
			}
		}
		
		print("✅ UpdatesService: Total star updates: \(updates.count)")
		return updates
	}
	
	// MARK: - Fetch Comment Updates
	private func fetchCommentUpdates(userId: String) async throws -> [UpdateItem] {
		var updates: [UpdateItem] = []
		
		print("🔍 UpdatesService: Fetching comment updates for user \(userId)")
		
		// Get all posts owned by current user
		// CRITICAL FIX: Add limit to prevent loading thousands of posts
		// Only check recent posts (last 100) for updates to keep it fast
		let postsSnapshot = try await db.collection("posts")
			.whereField("authorId", isEqualTo: userId)
			.order(by: "createdAt", descending: true)
			.limit(to: 100) // Only check last 100 posts for comments
			.getDocuments()
		
		print("✅ UpdatesService: Found \(postsSnapshot.documents.count) posts owned by user \(userId)")
		
		for postDoc in postsSnapshot.documents {
			let postId = postDoc.documentID
			let postData = postDoc.data()
			
			// Get all comments for this post
			let commentsSnapshot = try await db.collection("posts")
				.document(postId)
				.collection("comments")
				.order(by: "createdAt", descending: true)
				.limit(to: 50) // Increased limit to get more comments
				.getDocuments()
			
			print("💬 UpdatesService: Post \(postId) has \(commentsSnapshot.documents.count) comments")
			
			for commentDoc in commentsSnapshot.documents {
				let commentData = commentDoc.data()
				guard let commentUserId = commentData["userId"] as? String else {
					print("⚠️ UpdatesService: Comment document missing userId")
					continue
				}
				
				// Don't show own comments
				if commentUserId == userId {
					continue
				}
				
				print("💬 UpdatesService: Processing comment from user \(commentUserId) on post \(postId)")
				
				// Get user info who commented
				guard let user = try? await UserService.shared.getUser(userId: commentUserId) else {
					print("⚠️ UpdatesService: Could not fetch user \(commentUserId)")
					continue
				}
				
				let commentText = commentData["text"] as? String ?? ""
				let parentCommentId = commentData["parentCommentId"] as? String
				let isReply = parentCommentId != nil
				
				// Get post thumbnail
				let mediaItems = postData["mediaItems"] as? [[String: Any]] ?? []
				let firstMedia = mediaItems.first
				let thumbnailURL = firstMedia?["thumbnailURL"] as? String ?? firstMedia?["imageURL"] as? String
				
				let createdAt = (commentData["createdAt"] as? Timestamp)?.dateValue() ?? Date()
				
				let update = UpdateItem(
					id: "comment_\(postId)_\(commentDoc.documentID)",
					type: isReply ? .reply : .comment,
					userId: commentUserId,
					username: user.username,
					profileImageURL: user.profileImageURL,
					text: user.username,
					subText: isReply ? "Replied: \(commentText.prefix(60))" : "Commented: \(commentText.prefix(60))",
					timestamp: createdAt,
					postId: postId,
					collectionId: nil,
					thumbnailURL: thumbnailURL
				)
				updates.append(update)
				print("✅ UpdatesService: Added comment update for post \(postId) from \(user.username)")
			}
		}
		
		print("✅ UpdatesService: Total comment updates: \(updates.count)")
		return updates
	}
	
	// MARK: - Fetch New Post Updates
	private func fetchNewPostUpdates(userId: String) async throws -> [UpdateItem] {
		var updates: [UpdateItem] = []
		
		// Get all collections where user is a member
		// CRITICAL FIX: Add limit to prevent loading all collections
		let collectionsSnapshot = try await db.collection("collections")
			.whereField("members", arrayContains: userId)
			.limit(to: 100) // Limit to 100 collections max
			.getDocuments()
		
		for collectionDoc in collectionsSnapshot.documents {
			let collectionId = collectionDoc.documentID
			let collectionData = collectionDoc.data()
			let collectionName = collectionData["name"] as? String ?? "Collection"
			
			// Get recent posts in this collection (last 24 hours or last 10 posts)
			let oneDayAgo = Timestamp(date: Date().addingTimeInterval(-86400))
			let postsSnapshot = try await db.collection("posts")
				.whereField("collectionId", isEqualTo: collectionId)
				.whereField("createdAt", isGreaterThan: oneDayAgo)
				.order(by: "createdAt", descending: true)
				.limit(to: 20)
				.getDocuments()
			
			// Group by author
			var postsByAuthor: [String: [CollectionPost]] = [:]
			for postDoc in postsSnapshot.documents {
				let postData = postDoc.data()
				guard let authorId = postData["authorId"] as? String,
					  authorId != userId else { continue } // Don't show own posts
				
				// Parse media items
				let mediaItemsData = postData["mediaItems"] as? [[String: Any]] ?? []
				let mediaItems = mediaItemsData.map { mediaData -> MediaItem in
					MediaItem(
						imageURL: mediaData["imageURL"] as? String,
						thumbnailURL: mediaData["thumbnailURL"] as? String,
						videoURL: mediaData["videoURL"] as? String,
						videoDuration: mediaData["videoDuration"] as? Double,
						isVideo: mediaData["isVideo"] as? Bool ?? false
					)
				}
				
				let post = CollectionPost(
					id: postDoc.documentID,
					title: postData["title"] as? String ?? "",
					collectionId: collectionId,
					authorId: authorId,
					authorName: postData["authorName"] as? String ?? "",
					createdAt: (postData["createdAt"] as? Timestamp)?.dateValue() ?? Date(),
					firstMediaItem: mediaItems.first,
					mediaItems: mediaItems,
					isPinned: postData["isPinned"] as? Bool ?? false,
					pinnedAt: (postData["pinnedAt"] as? Timestamp)?.dateValue(),
					caption: postData["caption"] as? String,
					allowReplies: postData["allowReplies"] as? Bool ?? true,
					allowDownload: postData["allowDownload"] as? Bool ?? false,
					taggedUsers: postData["taggedUsers"] as? [String] ?? []
				)
				
				if postsByAuthor[authorId] == nil {
					postsByAuthor[authorId] = []
				}
				postsByAuthor[authorId]?.append(post)
			}
			
			// Create updates for each author
			for (authorId, posts) in postsByAuthor {
				guard let firstPost = posts.first else { continue }
				guard let author = try? await UserService.shared.getUser(userId: authorId) else { continue }
				
				let thumbnailURL = firstPost.firstMediaItem?.thumbnailURL ?? firstPost.firstMediaItem?.imageURL
				
				if posts.count == 1 {
					// Single post
					let update = UpdateItem(
						id: "post_\(collectionId)_\(authorId)_\(firstPost.id)",
						type: .newPost,
						userId: authorId,
						username: author.username,
						profileImageURL: author.profileImageURL,
						text: "\(author.username) has posted in the collection \"\(collectionName)\"",
						subText: nil,
						timestamp: firstPost.createdAt,
						postId: firstPost.id,
						collectionId: collectionId,
						thumbnailURL: thumbnailURL
					)
					updates.append(update)
				} else {
					// Multiple posts - batch notification
					let update = UpdateItem(
						id: "posts_\(collectionId)_\(authorId)_\(posts.count)",
						type: .newPost,
						userId: authorId,
						username: author.username,
						profileImageURL: author.profileImageURL,
						text: "\(posts.count) new posts in \"\(collectionName)\"",
						subText: "\(author.username) and \(posts.count - 1) others posted",
						timestamp: firstPost.createdAt,
						postId: firstPost.id,
						collectionId: collectionId,
						thumbnailURL: thumbnailURL
					)
					updates.append(update)
				}
			}
		}
		
		return updates
	}
	
	// MARK: - Fetch Starred By Users (for Starred By list)
	func fetchStarredByUsers(postId: String) async throws -> [CYUser] {
		// CRITICAL FIX: Add limit to prevent loading thousands of stars
		let starsSnapshot = try await db.collection("posts")
			.document(postId)
			.collection("stars")
			.order(by: "starredAt", descending: true)
			.limit(to: 100) // Only show first 100 users who starred
			.getDocuments()
		
		var users: [CYUser] = []
		for starDoc in starsSnapshot.documents {
			let starData = starDoc.data()
			guard let userId = starData["userId"] as? String,
				  let appUser = try? await UserService.shared.getUser(userId: userId) else { continue }
			
			// Convert AppUser to CYUser
			let cyUser = CYUser(
				id: appUser.userId,
				name: appUser.name,
				username: appUser.username,
				profileImageURL: appUser.profileImageURL ?? ""
			)
			users.append(cyUser)
		}
		
		return users
	}
	
	// MARK: - Fetch Action Required Updates
	func fetchActionRequiredUpdates() async throws -> [ActionRequiredUpdate] {
		guard let currentUserId = Auth.auth().currentUser?.uid else {
			throw NSError(domain: "UpdatesService", code: -1, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])
		}
		
		let db = Firestore.firestore()
		
		// Fetch all pending notifications that require action
		// CRITICAL FIX: Add limit to prevent loading all notifications
		let snapshot = try await db.collection("notifications")
			.whereField("userId", isEqualTo: currentUserId)
			.whereField("status", isEqualTo: "pending")
			.order(by: "timestamp", descending: true)
			.limit(to: 50) // Only show first 50 pending notifications
			.getDocuments()
		
		var actionUpdates: [ActionRequiredUpdate] = []
		
		for doc in snapshot.documents {
			let data = doc.data()
			let type = data["type"] as? String ?? ""
			let relatedUserId = data["relatedUserId"] as? String
			let relatedCollectionId = data["relatedCollectionId"] as? String
			
			// Only include action-required types
			guard ["collection_invitation", "collection_request", "collection_follow", "collection_join"].contains(type),
				  let userId = relatedUserId else { continue }
			
			// Get user info
			guard let user = try? await UserService.shared.getUser(userId: userId) else { continue }
			
			// Get collection info if needed
			var collectionName = ""
			var collectionImageURL: String? = nil
			if let collectionId = relatedCollectionId, !collectionId.isEmpty {
				if let collectionDoc = try? await db.collection("collections").document(collectionId).getDocument(),
				   let collectionData = collectionDoc.data() {
					collectionName = collectionData["name"] as? String ?? ""
					collectionImageURL = collectionData["imageURL"] as? String
				}
			}
			
			let body = data["body"] as? String ?? ""
			let timestamp = (data["timestamp"] as? Timestamp)?.dateValue() ?? Date()
			
			let actionType: ActionRequiredType
			switch type {
			case "collection_invitation":
				actionType = .invitation
			case "collection_request":
				actionType = .request
			case "collection_follow":
				actionType = .follow
			case "collection_join":
				actionType = .join
			default:
				continue
			}
			
			let update = ActionRequiredUpdate(
				id: doc.documentID,
				type: actionType,
				userId: userId,
				username: user.username,
				profileImageURL: user.profileImageURL,
				text: body,
				timestamp: timestamp,
				collectionId: relatedCollectionId,
				collectionName: collectionName,
				collectionImageURL: collectionImageURL
			)
			actionUpdates.append(update)
		}
		
		return actionUpdates
	}
}

// MARK: - Update Item Model
struct UpdateItem: Identifiable {
	let id: String
	let type: UpdateType
	let userId: String
	let username: String
	let profileImageURL: String?
	let text: String
	let subText: String? // Username for stars, comment text for comments
	let timestamp: Date
	let postId: String?
	let collectionId: String?
	let thumbnailURL: String?
}

enum UpdateType {
	case star
	case comment
	case reply
	case newPost
}

// MARK: - Action Required Update Model
struct ActionRequiredUpdate: Identifiable {
	let id: String
	let type: ActionRequiredType
	let userId: String
	let username: String
	let profileImageURL: String?
	let text: String
	let timestamp: Date
	let collectionId: String?
	let collectionName: String
	let collectionImageURL: String?
}

enum ActionRequiredType {
	case invitation // Invite to join private collection
	case request // Request to join private collection
	case follow // Someone followed my collection
	case join // Someone joined my open collection
}

