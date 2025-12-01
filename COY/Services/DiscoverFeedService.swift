import Foundation
import FirebaseFirestore
import FirebaseAuth

/// Service for Discover feed ranking algorithm
/// Uses rule-based scoring (NOT engagement-based) for variety and freshness
@MainActor
final class DiscoverFeedService {
	static let shared = DiscoverFeedService()
	private init() {}
	
	// MARK: - Discover Feed Item Types
	enum DiscoverItem {
		case collection(CollectionData)
		case post(CollectionPost, collection: CollectionData)
	}
	
	// MARK: - Discover Feed Scoring
	/// Calculate discover score for a collection
	func calculateCollectionScore(
		collection: CollectionData,
		currentUserId: String,
		followingCreatorIds: Set<String>,
		friendsData: FriendsData,
		userLocation: UserLocation?
	) -> Double {
		var score: Double = 0.0
		let now = Date()
		
		// 1. Affinity Boost (creators the user already follows)
		if followingCreatorIds.contains(collection.ownerId) {
			score += 10.0
		}
		
		// 2. Friends Boost
		// Friends who joined the collection
		let friendsWhoJoined = friendsData.friendsWhoJoinedCollection(collectionId: collection.id)
		score += 8.0 * Double(friendsWhoJoined.count)
		
		// Friends who follow the creator
		let friendsWhoFollowCreator = friendsData.friendsWhoFollowCreator(creatorId: collection.ownerId)
		score += 4.0 * Double(friendsWhoFollowCreator.count)
		
		// Friends who liked posts in this collection
		let friendsWhoLiked = friendsData.friendsWhoLikedCollection(collectionId: collection.id)
		score += 3.0 * Double(friendsWhoLiked.count)
		
		// Friends who posted in this collection
		let friendsWhoPosted = friendsData.friendsWhoPostedInCollection(collectionId: collection.id)
		score += 6.0 * Double(friendsWhoPosted.count)
		
		// 3. Popularity Boost
		score += Double(collection.memberCount) / 50.0
		// Note: postCount would need to be fetched separately or stored on collection
		// For now, we'll use memberCount as a proxy for popularity
		
		// 4. Location Boost
		if userLocation != nil {
			// Check if collection owner is in same city/region
			// This would require location data on user profiles
			// For now, we'll skip this or implement if location data is available
		}
		
		// 5. Recency Boost
		let timeSinceCreation = now.timeIntervalSince(collection.createdAt)
		let hoursSinceCreation = timeSinceCreation / 3600.0
		let recencyBoost = max(0.0, 10.0 - hoursSinceCreation)
		score += recencyBoost
		
		// 6. Random Shuffle (VERY important for freshness)
		score += Double.random(in: 0...3)
		
		return score
	}
	
	/// Calculate discover score for a post
	func calculatePostScore(
		post: CollectionPost,
		collection: CollectionData,
		currentUserId: String,
		followingCreatorIds: Set<String>,
		friendsData: FriendsData,
		userLocation: UserLocation?
	) -> Double {
		var score: Double = 0.0
		let now = Date()
		
		// 1. Affinity Boost (creators the user already follows)
		if followingCreatorIds.contains(post.authorId) {
			score += 10.0
		}
		
		// 2. Friends Boost
		// Friends who liked this post
		let friendsWhoLiked = friendsData.friendsWhoLikedPost(postId: post.id)
		score += 3.0 * Double(friendsWhoLiked.count)
		
		// Friends who follow the creator
		let friendsWhoFollowCreator = friendsData.friendsWhoFollowCreator(creatorId: post.authorId)
		score += 4.0 * Double(friendsWhoFollowCreator.count)
		
		// Friends who are members of the collection
		let friendsInCollection = friendsData.friendsInCollection(collectionId: collection.id)
		score += 6.0 * Double(friendsInCollection.count)
		
		// 3. Popularity Boost (lightweight - don't rely heavily on engagement)
		// Use collection popularity as proxy
		score += Double(collection.memberCount) / 50.0
		
		// 4. Location Boost
		if userLocation != nil {
			// Check if post author is in same city/region
			// This would require location data on user profiles
		}
		
		// 5. Recency Boost
		let timeSinceCreation = now.timeIntervalSince(post.createdAt)
		let hoursSinceCreation = timeSinceCreation / 3600.0
		let recencyBoost = max(0.0, 10.0 - hoursSinceCreation)
		score += recencyBoost
		
		// 6. Random Shuffle (VERY important for freshness)
		score += Double.random(in: 0...3)
		
		return score
	}
	
	// MARK: - Load Discover Feed
	/// Load and rank discover feed items (collections + posts)
	func loadDiscoverFeed(
		currentUserId: String,
		limit: Int = 50,
		excludeCollectionIds: Set<String> = [],
		excludePostIds: Set<String> = []
	) async throws -> (collections: [CollectionData], posts: [(post: CollectionPost, collection: CollectionData)]) {
		let db = Firestore.firestore()
		
		// Load user's following list
		let followingCollections = try await CollectionService.shared.getFollowedCollections(userId: currentUserId)
		let followingCreatorIds = Set(followingCollections.map { $0.ownerId })
		
		// Load friends data
		let friendsData = try await loadFriendsData(currentUserId: currentUserId)
		
		// Load user location (if available)
		let userLocation = try? await loadUserLocation(userId: currentUserId)
		
		// Load collections (public + accessible private)
		var allCollections: [CollectionData] = []
		let collectionsSnapshot = try await db.collection("collections")
			.whereField("isPublic", isEqualTo: true)
			.order(by: "createdAt", descending: true)
			.limit(to: 200)
			.getDocuments()
		
		for doc in collectionsSnapshot.documents {
			let data = doc.data()
			let ownerId = data["ownerId"] as? String ?? ""
			let ownersArray = data["owners"] as? [String]
			let owners = ownersArray ?? [ownerId]
			
			let collection = CollectionData(
				id: doc.documentID,
				name: data["name"] as? String ?? "",
				description: data["description"] as? String ?? "",
				type: data["type"] as? String ?? "Individual",
				isPublic: data["isPublic"] as? Bool ?? false,
				ownerId: ownerId,
				ownerName: data["ownerName"] as? String ?? "",
				owners: owners,
				imageURL: data["imageURL"] as? String,
				invitedUsers: data["invitedUsers"] as? [String] ?? [],
				members: data["members"] as? [String] ?? [],
				memberCount: data["memberCount"] as? Int ?? 0,
				followers: data["followers"] as? [String] ?? [],
				followerCount: data["followerCount"] as? Int ?? 0,
				allowedUsers: data["allowedUsers"] as? [String] ?? [],
				deniedUsers: data["deniedUsers"] as? [String] ?? [],
				createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
			)
			
			// Filter out excluded, owned, member, hidden collections
			if excludeCollectionIds.contains(collection.id) { continue }
			if collection.ownerId == currentUserId { continue }
			if collection.members.contains(currentUserId) { continue }
			if !CollectionService.canUserViewCollection(collection, userId: currentUserId) { continue }
			
			allCollections.append(collection)
		}
		
		// Load posts from public collections
		var allPosts: [(post: CollectionPost, collection: CollectionData)] = []
		let postsSnapshot = try await db.collection("posts")
			.order(by: "createdAt", descending: true)
			.limit(to: 200)
			.getDocuments()
		
		for doc in postsSnapshot.documents {
			guard let post = try? PostService.shared.parsePost(from: doc) else { continue }
			
			// Filter out excluded posts and posts from excluded collections
			if excludePostIds.contains(post.id) { continue }
			if excludeCollectionIds.contains(post.collectionId) { continue }
			if post.authorId == currentUserId { continue }
			
			// Get collection for this post
			guard let collection = try? await CollectionService.shared.getCollection(collectionId: post.collectionId) else { continue }
			
			// Filter out posts from collections user owns/is member of
			if collection.ownerId == currentUserId { continue }
			if collection.members.contains(currentUserId) { continue }
			if !CollectionService.canUserViewCollection(collection, userId: currentUserId) { continue }
			
			allPosts.append((post: post, collection: collection))
		}
		
		// Score and rank collections
		var scoredCollections = allCollections.map { collection -> (collection: CollectionData, score: Double) in
			let score = calculateCollectionScore(
				collection: collection,
				currentUserId: currentUserId,
				followingCreatorIds: followingCreatorIds,
				friendsData: friendsData,
				userLocation: userLocation
			)
			return (collection: collection, score: score)
		}
		scoredCollections.sort { $0.score > $1.score }
		
		// Score and rank posts
		var scoredPosts = allPosts.map { item -> (item: (post: CollectionPost, collection: CollectionData), score: Double) in
			let score = calculatePostScore(
				post: item.post,
				collection: item.collection,
				currentUserId: currentUserId,
				followingCreatorIds: followingCreatorIds,
				friendsData: friendsData,
				userLocation: userLocation
			)
			return (item: item, score: score)
		}
		scoredPosts.sort { $0.score > $1.score }
		
		// Take top items
		let topCollections = Array(scoredCollections.prefix(limit).map { $0.collection })
		let topPosts = Array(scoredPosts.prefix(limit).map { $0.item })
		
		return (collections: topCollections, posts: topPosts)
	}
	
	// MARK: - Friends Data Loading
	struct FriendsData {
		let friends: [String] // Friend user IDs
		let friendsCollections: [String: Set<String>] // [friendId: Set<collectionIds>]
		let friendsFollowing: [String: Set<String>] // [friendId: Set<creatorIds>]
		let friendsLikedPosts: [String: Set<String>] // [friendId: Set<postIds>]
		let friendsLikedCollections: [String: Set<String>] // [friendId: Set<collectionIds>]
		let friendsPostedIn: [String: Set<String>] // [friendId: Set<collectionIds>]
		
		func friendsWhoJoinedCollection(collectionId: String) -> [String] {
			return friends.filter { friendId in
				friendsCollections[friendId]?.contains(collectionId) ?? false
			}
		}
		
		func friendsWhoFollowCreator(creatorId: String) -> [String] {
			return friends.filter { friendId in
				friendsFollowing[friendId]?.contains(creatorId) ?? false
			}
		}
		
		func friendsWhoLikedPost(postId: String) -> [String] {
			return friends.filter { friendId in
				friendsLikedPosts[friendId]?.contains(postId) ?? false
			}
		}
		
		func friendsWhoLikedCollection(collectionId: String) -> [String] {
			return friends.filter { friendId in
				friendsLikedCollections[friendId]?.contains(collectionId) ?? false
			}
		}
		
		func friendsWhoPostedInCollection(collectionId: String) -> [String] {
			return friends.filter { friendId in
				friendsPostedIn[friendId]?.contains(collectionId) ?? false
			}
		}
		
		func friendsInCollection(collectionId: String) -> [String] {
			return friendsWhoJoinedCollection(collectionId: collectionId)
		}
	}
	
	private func loadFriendsData(currentUserId: String) async throws -> FriendsData {
		let db = Firestore.firestore()
		
		// Get user's friends list
		let userDoc = try await db.collection("users").document(currentUserId).getDocument()
		guard let userData = userDoc.data(),
			  let friends = userData["friends"] as? [String] else {
			return FriendsData(
				friends: [],
				friendsCollections: [:],
				friendsFollowing: [:],
				friendsLikedPosts: [:],
				friendsLikedCollections: [:],
				friendsPostedIn: [:]
			)
		}
		
		// Load friends' data in parallel
		var friendsCollections: [String: Set<String>] = [:]
		var friendsFollowing: [String: Set<String>] = [:]
		var friendsLikedPosts: [String: Set<String>] = [:]
		var friendsLikedCollections: [String: Set<String>] = [:]
		var friendsPostedIn: [String: Set<String>] = [:]
		
		await withTaskGroup(of: (String, Set<String>, Set<String>, Set<String>, Set<String>, Set<String>).self) { group in
			for friendId in friends {
				group.addTask {
					do {
						// Get friend's followed collections
						let followedCollections = try await CollectionService.shared.getFollowedCollections(userId: friendId)
						let followedIds = Set(followedCollections.map { $0.id })
						let followedCreators = Set(followedCollections.map { $0.ownerId })
						
						// Get friend's starred posts
						let friendDoc = try await db.collection("users").document(friendId).getDocument()
						let starredPostIds = Set(friendDoc.data()?["starredPostIds"] as? [String] ?? [])
						
						// Get collections friend is member of
						let collectionsSnapshot = try await db.collection("collections")
							.whereField("members", arrayContains: friendId)
							.limit(to: 100)
							.getDocuments()
						let memberCollectionIds = Set(collectionsSnapshot.documents.map { $0.documentID })
						
						// Get collections friend posted in
						let postsSnapshot = try await db.collection("posts")
							.whereField("authorId", isEqualTo: friendId)
							.limit(to: 100)
							.getDocuments()
						let postedCollectionIds = Set(postsSnapshot.documents.map { doc in
							doc.data()["collectionId"] as? String ?? ""
						}.filter { !$0.isEmpty })
						
						return (friendId, memberCollectionIds, followedCreators, starredPostIds, followedIds, postedCollectionIds)
					} catch {
						print("⚠️ DiscoverFeedService: Error loading friend data for \(friendId): \(error)")
						return (friendId, [], [], [], [], [])
					}
				}
			}
			
			for await (friendId, memberCollections, following, likedPosts, likedCollections, postedIn) in group {
				friendsCollections[friendId] = memberCollections
				friendsFollowing[friendId] = following
				friendsLikedPosts[friendId] = likedPosts
				friendsLikedCollections[friendId] = likedCollections
				friendsPostedIn[friendId] = postedIn
			}
		}
		
		return FriendsData(
			friends: friends,
			friendsCollections: friendsCollections,
			friendsFollowing: friendsFollowing,
			friendsLikedPosts: friendsLikedPosts,
			friendsLikedCollections: friendsLikedCollections,
			friendsPostedIn: friendsPostedIn
		)
	}
	
	// MARK: - User Location
	struct UserLocation {
		let city: String?
		let region: String?
	}
	
	private func loadUserLocation(userId: String) async throws -> UserLocation? {
		let db = Firestore.firestore()
		let userDoc = try await db.collection("users").document(userId).getDocument()
		guard let data = userDoc.data() else { return nil }
		
		// If location fields exist on user document, use them
		// Otherwise return nil (location boost will be skipped)
		let city = data["city"] as? String
		let region = data["region"] as? String
		
		if city != nil || region != nil {
			return UserLocation(city: city, region: region)
		}
		
		return nil
	}
}
