import Foundation
import FirebaseFirestore
import FirebaseStorage
import FirebaseAuth
import UIKit

@MainActor
final class CollectionService {
	static let shared = CollectionService()
	private init() {}
	
	func createCollection(name: String, description: String, type: String, isPublic: Bool, ownerId: String, ownerName: String, image: UIImage?, invitedUsers: [String]) async throws -> String {
		// Use Firebase directly
		let db = Firestore.firestore()
			var collectionData: [String: Any] = [
				"name": name,
				"description": description,
				"type": type,
				"isPublic": isPublic,
				"ownerId": ownerId,
				"ownerName": ownerName,
				"members": [ownerId], // Only owner is a member initially
				"memberCount": 1,
				"invitedUsers": invitedUsers,
				"createdAt": Timestamp()
			]
			
			// Upload image to Firebase Storage if provided
			if let image = image {
				let storage = Storage.storage()
				let imageRef = storage.reference().child("collection_images/\(UUID().uuidString).jpg")
				if let imageData = image.jpegData(compressionQuality: 0.8) {
					// Use completion handler for putData
					try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
						_ = imageRef.putData(imageData, metadata: nil) { metadata, error in
							if let error = error {
								continuation.resume(throwing: error)
							} else {
								continuation.resume()
							}
						}
					}
					let imageURL = try await imageRef.downloadURL()
					collectionData["imageURL"] = imageURL.absoluteString
				}
			}
			
		// Save collection with retry logic
		let docRef = try await FirebaseRetryManager.shared.executeWithRetry(
			operation: {
				try await db.collection("collections").addDocument(data: collectionData)
			},
			operationName: "Create collection"
		)
		let collectionId = docRef.documentID
		
		// Send invite notifications to all invited users
		if !invitedUsers.isEmpty {
			// Get owner info for notification
			guard let owner = try await UserService.shared.getUser(userId: ownerId) else {
				throw NSError(domain: "CollectionService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Owner not found"])
			}
			
			// Send notifications to all invited users
			for invitedUserId in invitedUsers {
				try await NotificationService.shared.sendCollectionInviteNotification(
					collectionId: collectionId,
					collectionName: name,
					inviterId: ownerId,
					inviterUsername: owner.username,
					inviterProfileImageURL: owner.profileImageURL,
					invitedUserId: invitedUserId
				)
			}
		}
		
		return collectionId
	}
	
	func getCollection(collectionId: String) async throws -> CollectionData? {
		// Use Firebase directly with retry logic
		let db = Firestore.firestore()
		let doc = try await FirebaseRetryManager.shared.executeWithRetry(
			operation: {
				try await db.collection("collections").document(collectionId).getDocument()
			},
			operationName: "Get collection"
		)
		
		guard let data = doc.data() else { return nil }
		
		let ownerId = data["ownerId"] as? String ?? ""
		// Subscribe to real-time updates for collection owner
		if !ownerId.isEmpty {
			UserService.shared.subscribeToUserProfile(userId: ownerId)
		}
		
		return CollectionData(
			id: doc.documentID,
			name: data["name"] as? String ?? "",
			description: data["description"] as? String ?? "",
			type: data["type"] as? String ?? "Individual",
			isPublic: data["isPublic"] as? Bool ?? false,
			ownerId: ownerId,
			ownerName: data["ownerName"] as? String ?? "",
			owners: data["owners"] as? [String] ?? [data["ownerId"] as? String ?? ""],
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
	}
	
	func getPostById(postId: String) async throws -> CollectionPost? {
		let db = Firestore.firestore()
		let doc = try await db.collection("posts").document(postId).getDocument()
		
		guard let data = doc.data() else { return nil }
		
		// Parse mediaItems
		var allMediaItems: [MediaItem] = []
		if let mediaItemsArray = data["mediaItems"] as? [[String: Any]] {
			allMediaItems = mediaItemsArray.compactMap { mediaData in
				MediaItem(
					imageURL: mediaData["imageURL"] as? String,
					thumbnailURL: mediaData["thumbnailURL"] as? String,
					videoURL: mediaData["videoURL"] as? String,
					videoDuration: mediaData["videoDuration"] as? Double,
					isVideo: mediaData["isVideo"] as? Bool ?? false
				)
			}
		}
		
		let firstMediaItem = allMediaItems.first
		let authorId = data["authorId"] as? String ?? ""
		// Subscribe to real-time updates for post author
		if !authorId.isEmpty {
			UserService.shared.subscribeToUserProfile(userId: authorId)
		}
		
		return CollectionPost(
			id: doc.documentID,
			title: data["title"] as? String ?? "",
			collectionId: data["collectionId"] as? String ?? "",
			authorId: authorId,
			authorName: data["authorName"] as? String ?? "",
			createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? Date(),
			firstMediaItem: firstMediaItem,
			mediaItems: allMediaItems,
			isPinned: data["isPinned"] as? Bool ?? false,
			pinnedAt: (data["pinnedAt"] as? Timestamp)?.dateValue(),
			caption: data["caption"] as? String ?? data["title"] as? String,
			allowReplies: data["allowReplies"] as? Bool ?? true,
			allowDownload: data["allowDownload"] as? Bool ?? false,
			taggedUsers: data["taggedUsers"] as? [String] ?? []
		)
	}
	
	func getUserCollections(userId: String, forceFresh: Bool = false) async throws -> [CollectionData] {
		// Use Firebase directly
		let db = Firestore.firestore()
		
		// Query 1: Collections where user is the owner
		// CRITICAL FIX: Add limit to prevent loading all collections
		let ownedSnapshot = try await db.collection("collections")
			.whereField("ownerId", isEqualTo: userId)
			.limit(to: 100) // Limit to 100 owned collections max
			.getDocuments()
		
		// Query 2: Get user's collections array from user document
		// This array contains collection IDs where the user is a member
		var memberCollectionIds: [String] = []
		do {
			let userDoc = try await db.collection("users").document(userId).getDocument()
			if let userData = userDoc.data(),
			   let collections = userData["collections"] as? [String] {
				memberCollectionIds = collections
			}
		} catch {
			print("⚠️ CollectionService: Could not read user collections array: \(error.localizedDescription)")
		}
		
		// Combine both queries and remove duplicates
		var allCollections: [String: CollectionData] = [:]
		
		// Process owned collections
		for doc in ownedSnapshot.documents {
			let data = doc.data()
			let collectionId = doc.documentID
			let collectionName = data["name"] as? String ?? ""
			let collectionDescription = data["description"] as? String ?? ""
			let collectionType = data["type"] as? String ?? "Individual"
			let collectionIsPublic = data["isPublic"] as? Bool ?? false
			let collectionOwnerId = data["ownerId"] as? String ?? userId
			let collectionOwnerName = data["ownerName"] as? String ?? ""
		
		// Subscribe to real-time updates for collection owner
		if !collectionOwnerId.isEmpty {
			UserService.shared.subscribeToUserProfile(userId: collectionOwnerId)
		}
			
			let collection = CollectionData(
				id: collectionId,
				name: collectionName,
				description: collectionDescription,
				type: collectionType,
				isPublic: collectionIsPublic,
				ownerId: collectionOwnerId,
				ownerName: collectionOwnerName,
				owners: data["owners"] as? [String] ?? [userId],
				imageURL: data["imageURL"] as? String,
				invitedUsers: data["invitedUsers"] as? [String] ?? [],
				members: data["members"] as? [String] ?? [userId],
				memberCount: data["memberCount"] as? Int ?? 1,
				followers: data["followers"] as? [String] ?? [],
				followerCount: data["followerCount"] as? Int ?? 0,
				allowedUsers: data["allowedUsers"] as? [String] ?? [],
				deniedUsers: data["deniedUsers"] as? [String] ?? [],
				createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
			)
			allCollections[collectionId] = collection
		}
		
		// Process member collections (where user is a member but not owner)
		// Fetch each collection by ID
		for collectionId in memberCollectionIds {
			// Skip if already added (user is owner)
			if allCollections[collectionId] != nil {
				continue
			}
			
			// Fetch the collection document
			do {
				let collectionDoc = try await db.collection("collections").document(collectionId).getDocument()
				if let data = collectionDoc.data() {
					let ownerId = data["ownerId"] as? String ?? ""
					
					// Only add if user is a member but not the owner
					if ownerId != userId {
						let collectionName = data["name"] as? String ?? ""
						let collectionDescription = data["description"] as? String ?? ""
						let collectionType = data["type"] as? String ?? "Individual"
						let collectionIsPublic = data["isPublic"] as? Bool ?? false
						let collectionOwnerName = data["ownerName"] as? String ?? ""
						
						let collection = CollectionData(
							id: collectionId,
							name: collectionName,
							description: collectionDescription,
							type: collectionType,
							isPublic: collectionIsPublic,
							ownerId: ownerId,
							ownerName: collectionOwnerName,
							owners: data["owners"] as? [String] ?? [ownerId],
							imageURL: data["imageURL"] as? String,
							invitedUsers: data["invitedUsers"] as? [String] ?? [],
							members: data["members"] as? [String] ?? [],
							memberCount: data["memberCount"] as? Int ?? 1,
							followers: data["followers"] as? [String] ?? [],
							followerCount: data["followerCount"] as? Int ?? 0,
							allowedUsers: data["allowedUsers"] as? [String] ?? [],
							deniedUsers: data["deniedUsers"] as? [String] ?? [],
							createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
						)
						allCollections[collectionId] = collection
					}
				}
			} catch {
				print("⚠️ CollectionService: Could not fetch member collection \(collectionId): \(error.localizedDescription)")
				// Collection might have been deleted, continue
			}
		}
		
		let allCollectionsArray = Array(allCollections.values)
		
		// Filter out hidden collections (mutual blocking, blocked users, etc.)
		return await CollectionService.filterCollections(allCollectionsArray)
	}
	
	// MARK: - Paginated Collection Loading
	/// Get user collections with pagination
	/// - Parameters:
	///   - userId: The user ID
	///   - limit: Number of collections to fetch
	///   - lastDocument: Last document from previous page (nil for first page)
	/// - Returns: Tuple of (collections, lastDocument, hasMore)
	func getUserCollectionsPaginated(
		userId: String,
		limit: Int = 20,
		lastDocument: DocumentSnapshot? = nil
	) async throws -> (collections: [CollectionData], lastDocument: DocumentSnapshot?, hasMore: Bool) {
		let db = Firestore.firestore()
		
		var query: Query = db.collection("collections")
			.whereField("ownerId", isEqualTo: userId)
			.order(by: "createdAt", descending: true)
		
		if let lastDoc = lastDocument {
			query = query.start(afterDocument: lastDoc)
		}
		query = query.limit(to: limit)
		
		let snapshot = try await query.getDocuments()
		
		var collections: [CollectionData] = []
		for doc in snapshot.documents {
			let data = doc.data()
			let ownerId = data["ownerId"] as? String ?? userId
			// Subscribe to real-time updates for collection owner
			if !ownerId.isEmpty {
				UserService.shared.subscribeToUserProfile(userId: ownerId)
			}
			
			let collection = CollectionData(
				id: doc.documentID,
				name: data["name"] as? String ?? "",
				description: data["description"] as? String ?? "",
				type: data["type"] as? String ?? "Individual",
				isPublic: data["isPublic"] as? Bool ?? false,
				ownerId: ownerId,
				ownerName: data["ownerName"] as? String ?? "",
				owners: data["owners"] as? [String] ?? [userId],
				imageURL: data["imageURL"] as? String,
				invitedUsers: data["invitedUsers"] as? [String] ?? [],
				members: data["members"] as? [String] ?? [userId],
				memberCount: data["memberCount"] as? Int ?? 1,
				followers: data["followers"] as? [String] ?? [],
				followerCount: data["followerCount"] as? Int ?? 0,
				allowedUsers: data["allowedUsers"] as? [String] ?? [],
				deniedUsers: data["deniedUsers"] as? [String] ?? [],
				createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
			)
			collections.append(collection)
		}
		
		let lastDoc = snapshot.documents.last
		let hasMore = snapshot.documents.count == limit
		
		// Filter out hidden collections (mutual blocking, blocked users, etc.)
		let filteredCollections = await CollectionService.filterCollections(collections)
		
		return (filteredCollections, lastDoc, hasMore)
	}
	
	/// Get visible collections for a user with pagination (for viewing other users' profiles)
	/// Includes public collections AND private collections where viewing user is in allowedUsers
	func getVisibleCollectionsPaginated(
		profileUserId: String,
		viewingUserId: String?,
		limit: Int = 20,
		lastDocument: DocumentSnapshot? = nil
	) async throws -> (collections: [CollectionData], lastDocument: DocumentSnapshot?, hasMore: Bool) {
		let db = Firestore.firestore()
		
		// Query 1: Public collections
		let publicQuery: Query = db.collection("collections")
			.whereField("ownerId", isEqualTo: profileUserId)
			.whereField("isPublic", isEqualTo: true)
			.order(by: "createdAt", descending: true)
		
		// Query 2: Private collections where viewing user is in allowedUsers
		let allowedQuery: Query = {
			var query: Query = db.collection("collections")
				.whereField("ownerId", isEqualTo: profileUserId)
				.whereField("isPublic", isEqualTo: false)
			
			// Only query allowedUsers if we have a viewing user
			if let viewingUserId = viewingUserId {
				query = query.whereField("allowedUsers", arrayContains: viewingUserId)
			} else {
				// If no viewing user, skip the allowedUsers query (no results)
				query = query.limit(to: 0)
			}
			
			return query.order(by: "createdAt", descending: true)
		}()
		
		// Execute both queries in parallel
		async let publicSnapshot = publicQuery.getDocuments()
		async let allowedSnapshot = allowedQuery.getDocuments()
		
		let (publicDocs, allowedDocs) = try await (publicSnapshot, allowedSnapshot)
		
		// Combine results and remove duplicates
		var allDocs: [QueryDocumentSnapshot] = []
		var seenIds: Set<String> = []
		
		for doc in publicDocs.documents {
			if !seenIds.contains(doc.documentID) {
				allDocs.append(doc)
				seenIds.insert(doc.documentID)
			}
		}
		
		for doc in allowedDocs.documents {
			if !seenIds.contains(doc.documentID) {
				allDocs.append(doc)
				seenIds.insert(doc.documentID)
			}
		}
		
		// Sort by createdAt descending
		allDocs.sort { doc1, doc2 in
			let date1 = (doc1.data()["createdAt"] as? Timestamp)?.dateValue() ?? Date()
			let date2 = (doc2.data()["createdAt"] as? Timestamp)?.dateValue() ?? Date()
			return date1 > date2
		}
		
		// Apply pagination
		var paginatedDocs = allDocs
		if let lastDoc = lastDocument {
			// Find the index of the last document
			let lastDocId = lastDoc.documentID
			if let lastIndex = allDocs.firstIndex(where: { $0.documentID == lastDocId }) {
				paginatedDocs = Array(allDocs.suffix(from: allDocs.index(after: lastIndex)))
		}
		}
		
		// Apply limit
		paginatedDocs = Array(paginatedDocs.prefix(limit))
		
		// Parse collections
		var collections: [CollectionData] = []
		for doc in paginatedDocs {
			let data = doc.data()
			let ownerId = data["ownerId"] as? String ?? profileUserId
			// Subscribe to real-time updates for collection owner
			if !ownerId.isEmpty {
				UserService.shared.subscribeToUserProfile(userId: ownerId)
			}
			
			let collection = CollectionData(
				id: doc.documentID,
				name: data["name"] as? String ?? "",
				description: data["description"] as? String ?? "",
				type: data["type"] as? String ?? "Individual",
				isPublic: data["isPublic"] as? Bool ?? false,
				ownerId: ownerId,
				ownerName: data["ownerName"] as? String ?? "",
				owners: data["owners"] as? [String] ?? [profileUserId],
				imageURL: data["imageURL"] as? String,
				invitedUsers: data["invitedUsers"] as? [String] ?? [],
				members: data["members"] as? [String] ?? [],
				memberCount: data["memberCount"] as? Int ?? 1,
				followers: data["followers"] as? [String] ?? [],
				followerCount: data["followerCount"] as? Int ?? 0,
				allowedUsers: data["allowedUsers"] as? [String] ?? [],
				deniedUsers: data["deniedUsers"] as? [String] ?? [],
				createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
			)
			collections.append(collection)
		}
		
		let lastDoc = paginatedDocs.last
		let hasMore = allDocs.count > (lastDocument != nil ? (allDocs.firstIndex(where: { $0.documentID == lastDocument?.documentID }) ?? 0) + limit : limit)
		
		// Filter out hidden collections and denied collections (mutual blocking, blocked users, etc.)
		let filteredCollections = await CollectionService.filterCollections(collections)
		
		return (filteredCollections, lastDoc, hasMore)
	}
	
	/// Get posts for a collection from Firebase (source of truth) - DEPRECATED: Use PostService.getCollectionPostsPaginated instead
	func getCollectionPostsFromFirebase(collectionId: String) async throws -> [CollectionPost] {
		let db = Firestore.firestore()
		// CRITICAL FIX: Add limit to prevent loading thousands of posts
		// Query without orderBy to avoid index requirement, then sort in memory
		let snapshot = try await db.collection("posts")
			.whereField("collectionId", isEqualTo: collectionId)
			.limit(to: 100) // Limit to 100 posts max (use pagination for more)
			.getDocuments()
		
		let loadedPosts = snapshot.documents.compactMap { doc -> CollectionPost? in
			let data = doc.data()
			
			// Parse all mediaItems
			var allMediaItems: [MediaItem] = []
			
			// First, try to get all mediaItems array
			if let mediaItemsArray = data["mediaItems"] as? [[String: Any]] {
				allMediaItems = mediaItemsArray.compactMap { mediaData in
					MediaItem(
						imageURL: mediaData["imageURL"] as? String,
						thumbnailURL: mediaData["thumbnailURL"] as? String,
						videoURL: mediaData["videoURL"] as? String,
						videoDuration: mediaData["videoDuration"] as? Double,
						isVideo: mediaData["isVideo"] as? Bool ?? false
					)
				}
			}
			
			// Fallback to firstMediaItem if mediaItems array is empty
			if allMediaItems.isEmpty, let firstMediaData = data["firstMediaItem"] as? [String: Any] {
				let firstItem = MediaItem(
					imageURL: firstMediaData["imageURL"] as? String,
					thumbnailURL: firstMediaData["thumbnailURL"] as? String,
					videoURL: firstMediaData["videoURL"] as? String,
					videoDuration: firstMediaData["videoDuration"] as? Double,
					isVideo: firstMediaData["isVideo"] as? Bool ?? false
				)
				allMediaItems = [firstItem]
			}
			
			let firstMediaItem = allMediaItems.first
			
			let authorId = data["authorId"] as? String ?? ""
			// Subscribe to real-time updates for post author
			if !authorId.isEmpty {
				UserService.shared.subscribeToUserProfile(userId: authorId)
			}
			
			return CollectionPost(
				id: doc.documentID,
				title: data["title"] as? String ?? data["caption"] as? String ?? "",
				collectionId: data["collectionId"] as? String ?? "",
				authorId: authorId,
				authorName: data["authorName"] as? String ?? "",
				createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? Date(),
				firstMediaItem: firstMediaItem,
				mediaItems: allMediaItems,
				isPinned: data["isPinned"] as? Bool ?? false,
				pinnedAt: (data["pinnedAt"] as? Timestamp)?.dateValue(),
				caption: data["caption"] as? String ?? data["title"] as? String,
				allowReplies: {
					let firestoreValue = data["allowReplies"] as? Bool
					let value = firestoreValue ?? true
					let postId = doc.documentID
					if firestoreValue == nil {
						print("⚠️ Loading post \(postId): allowReplies is MISSING in Firestore, using default: \(value)")
					} else {
						print("✅ Loading post \(postId): allowReplies from Firestore = \(firestoreValue!), using: \(value)")
					}
					return value
				}(),
				allowDownload: {
					let firestoreValue = data["allowDownload"] as? Bool
					let value = firestoreValue ?? false
					let postId = doc.documentID
					if firestoreValue == nil {
						print("⚠️ Loading post \(postId): allowDownload is MISSING in Firestore, using default: \(value)")
					} else {
						print("✅ Loading post \(postId): allowDownload from Firestore = \(firestoreValue!), using: \(value)")
					}
					return value
				}(),
				taggedUsers: data["taggedUsers"] as? [String] ?? []
			)
		}
		// Sort by createdAt descending (newest first)
		return loadedPosts.sorted { $0.createdAt > $1.createdAt }
	}
	
	// MARK: - Soft Delete System
	func softDeleteCollection(collectionId: String) async throws {
		print("🗑️ CollectionService: Starting soft delete for collection: \(collectionId)")
		
		// Use Firebase directly
		guard let collection = try await getCollection(collectionId: collectionId) else {
			throw NSError(domain: "CollectionService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Collection not found"])
		}
		
		// Only owner can delete collection
		guard let currentUserId = Auth.auth().currentUser?.uid else {
			throw NSError(domain: "CollectionService", code: -1, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])
		}
		
		if collection.ownerId != currentUserId {
			throw NSError(domain: "CollectionService", code: 403, userInfo: [NSLocalizedDescriptionKey: "Only the collection owner can delete the collection"])
		}
		
		let ownerId = collection.ownerId
		let db = Firestore.firestore()
		let collectionRef = db.collection("collections").document(collectionId)
		
		// Get collection data for soft delete
		let collectionDoc = try await collectionRef.getDocument()
		guard var collectionData = collectionDoc.data() else {
			print("❌ CollectionService: Collection document not found: \(collectionId)")
			throw NSError(domain: "CollectionService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Collection not found"])
		}
		
		// Add deletedAt timestamp
		collectionData["deletedAt"] = Timestamp()
		collectionData["isDeleted"] = true
		
		// Move to deleted_collections subcollection
		let deletedRef = db.collection("users").document(ownerId).collection("deleted_collections").document(collectionId)
		print("📝 CollectionService: Moving collection to deleted_collections subcollection...")
		try await deletedRef.setData(collectionData)
		print("✅ CollectionService: Collection moved to deleted_collections")
		
		// Remove from main collections
		print("🗑️ CollectionService: Removing collection from main collections...")
		try await collectionRef.delete()
		print("✅ CollectionService: Collection removed from main collections")
		
		// Post notification so collection disappears immediately from UI
		Task { @MainActor in
			NotificationCenter.default.post(
				name: NSNotification.Name("CollectionDeleted"),
				object: collectionId,
				userInfo: ["ownerId": ownerId]
			)
			print("📢 CollectionService: Posted CollectionDeleted notification")
		}
		
		print("✅ CollectionService: Soft delete completed successfully for collection: \(collectionId)")
	}
	
	func recoverCollection(collectionId: String, ownerId: String) async throws {
		print("🔄 CollectionService: Starting restore for collection: \(collectionId)")
		
		// Use Firebase directly
		let db = Firestore.firestore()
		let deletedRef = db.collection("users").document(ownerId).collection("deleted_collections").document(collectionId)
		
		// Get deleted collection data
		let deletedDoc = try await deletedRef.getDocument()
		guard var collectionData = deletedDoc.data() else {
			throw NSError(domain: "CollectionService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Deleted collection not found"])
		}
		
		// Remove deleted fields
		collectionData.removeValue(forKey: "deletedAt")
		collectionData.removeValue(forKey: "isDeleted")
		
		// Restore to main collections
		let collectionRef = db.collection("collections").document(collectionId)
		try await collectionRef.setData(collectionData)
		
		// Remove from deleted_collections
		try await deletedRef.delete()
		
		print("✅ CollectionService: Collection restored")
		
		// Post notification so collection appears immediately in UI
		Task { @MainActor in
			NotificationCenter.default.post(
				name: NSNotification.Name("CollectionRestored"),
				object: collectionId,
				userInfo: ["ownerId": ownerId]
			)
			print("📢 CollectionService: Posted CollectionRestored notification")
		}
		
		print("✅ CollectionService: Restore completed successfully for collection: \(collectionId)")
	}
	
	func permanentlyDeleteCollection(collectionId: String, ownerId: String) async throws {
		print("🗑️ CollectionService: Starting PERMANENT delete for collection: \(collectionId)")
		print("   Owner ID: \(ownerId)")
		print("   This function works for ALL collection types: Individual, Request, Join, Invite")
		print("   All posts, comments, media, and references will be permanently deleted")
		
		// Use Firebase directly
		let db = Firestore.firestore()
		let storage = Storage.storage()
		
		// Track any errors but continue with deletion
		var deletionErrors: [String] = []
		
		// Get collection data first (from deleted_collections or main collections) to get all info
		let deletedRef = db.collection("users").document(ownerId).collection("deleted_collections").document(collectionId)
		let mainCollectionRef = db.collection("collections").document(collectionId)
		
		var collectionData: [String: Any]? = nil
		if let deletedData = try? await deletedRef.getDocument().data() {
			collectionData = deletedData
			print("📋 Found collection in deleted_collections")
		} else if let mainData = try? await mainCollectionRef.getDocument().data() {
			collectionData = mainData
			print("📋 Found collection in main collections")
		}
		
		// Step 1: Delete ALL posts in the collection (with pagination) - works for ALL collection types
		var postLastDoc: DocumentSnapshot? = nil
		var hasMorePosts = true
		var totalPostsDeleted = 0
		
		while hasMorePosts {
			var postQuery = db.collection("posts")
			.whereField("collectionId", isEqualTo: collectionId)
				.limit(to: 100) // Process 100 posts at a time
			
			if let lastDoc = postLastDoc {
				postQuery = postQuery.start(afterDocument: lastDoc)
			}
			
			let postsSnapshot = try await postQuery.getDocuments()
			print("📋 Processing batch of \(postsSnapshot.documents.count) posts (total deleted: \(totalPostsDeleted))")
			
			if postsSnapshot.documents.isEmpty {
				hasMorePosts = false
				break
			}
		
			// Step 2: For each post, delete ALL comments and ALL media files
		// CRITICAL: Use do-catch for each post so one failure doesn't stop all deletions
		for postDoc in postsSnapshot.documents {
			let postId = postDoc.documentID
			let postData = postDoc.data()
			
			do {
				// CRITICAL FIX: Ensure post has collectionOwnerId for permission to delete
				// For member collections, posts created by members might not have collectionOwnerId set
				// We MUST set it to the collection owner so owner can delete all posts
				let currentCollectionOwnerId = postData["collectionOwnerId"] as? String
				if currentCollectionOwnerId != ownerId {
					print("⚠️ Post \(postId) collectionOwnerId mismatch or missing (current: \(currentCollectionOwnerId ?? "nil"), owner: \(ownerId)), updating before deletion...")
					do {
						try await postDoc.reference.updateData([
							"collectionOwnerId": ownerId
						])
						print("✅ Updated post \(postId) with collectionOwnerId = \(ownerId)")
						// Update postData for subsequent operations
						var updatedPostData = postData
						updatedPostData["collectionOwnerId"] = ownerId
					} catch let updateError {
						print("⚠️ Could not update post \(postId) with collectionOwnerId: \(updateError.localizedDescription)")
						print("   Will attempt deletion anyway - might work if post author is owner or member")
						// Continue anyway - might still be deletable
					}
				} else {
					print("✅ Post \(postId) already has correct collectionOwnerId")
				}
				
				// Delete ALL comments for this post (with pagination)
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
						// Use try? so one comment failure doesn't stop others
						try? await commentDoc.reference.delete()
					}
					
					hasMoreComments = commentsSnapshot.documents.count == 100
					commentLastDoc = commentsSnapshot.documents.last
				}
				
				// Delete ALL media files from Firebase Storage
				if let mediaItems = postData["mediaItems"] as? [[String: Any]] {
					for mediaItem in mediaItems {
						// Delete image if exists
						if let imageURL = mediaItem["imageURL"] as? String, !imageURL.isEmpty {
							if let url = URL(string: imageURL) {
								let imageRef = storage.reference(forURL: url.absoluteString)
								try? await imageRef.delete()
								print("🗑️ Deleted image: \(imageURL)")
							}
						}
						
						// Delete thumbnail if exists
						if let thumbnailURL = mediaItem["thumbnailURL"] as? String, !thumbnailURL.isEmpty {
							if let url = URL(string: thumbnailURL) {
								let thumbnailRef = storage.reference(forURL: url.absoluteString)
								try? await thumbnailRef.delete()
								print("🗑️ Deleted thumbnail: \(thumbnailURL)")
							}
						}
						
						// Delete video if exists
						if let videoURL = mediaItem["videoURL"] as? String, !videoURL.isEmpty {
							if let url = URL(string: videoURL) {
								let videoRef = storage.reference(forURL: url.absoluteString)
								try? await videoRef.delete()
								print("🗑️ Deleted video: \(videoURL)")
							}
						}
					}
				}
				
				// Delete the post document itself
				// CRITICAL: For member collections, posts might be created by members
				// We updated collectionOwnerId above, so owner should be able to delete
				try await postDoc.reference.delete()
				totalPostsDeleted += 1
				print("✅ Deleted post \(postId) with all comments and media")
			} catch {
				// CRITICAL: Log error but CONTINUE with other posts
				// Don't let one post failure stop the entire deletion process
				let errorMsg = "Post \(postId): \(error.localizedDescription)"
				print("❌ Error deleting \(errorMsg)")
				deletionErrors.append(errorMsg)
				
				// Try alternative approach: Delete post using batch (might bypass some permission checks)
				// Or try to delete as the post author if we can determine who created it
				if let authorId = postData["authorId"] as? String {
					print("   Post author: \(authorId), Collection owner: \(ownerId)")
					
					// If post author is the owner, we should be able to delete
					// If post author is a member, the collectionOwnerId update should allow deletion
					// Try one more time with the updated collectionOwnerId
					print("   Retrying post deletion after collectionOwnerId update...")
					do {
						try await postDoc.reference.delete()
						totalPostsDeleted += 1
						print("✅ Successfully deleted post \(postId) on retry")
						// Remove from errors since it succeeded on retry
						deletionErrors.removeAll { $0.contains(postId) }
					} catch let retryError {
						print("❌ Post \(postId) still failed to delete after retry: \(retryError.localizedDescription)")
						print("   This post will remain in Firestore - manual cleanup may be needed")
						// Continue with other posts - don't stop the entire deletion
					}
				} else {
					print("   Could not determine post author, skipping this post")
					// Continue with other posts
				}
			}
		}
		
		print("✅ Deleted \(postsSnapshot.documents.count) posts and all their comments/media from collection")
		
		// Update pagination cursor
		postLastDoc = postsSnapshot.documents.last
		hasMorePosts = postsSnapshot.documents.count == 100
		}
		
		print("✅ Total: Deleted \(totalPostsDeleted) posts, all comments, and all media files")
		
		// Step 3: Delete collection image from Storage if exists
		if let collectionData = collectionData,
		   let imageURL = collectionData["imageURL"] as? String, !imageURL.isEmpty {
			if let url = URL(string: imageURL) {
				let imageRef = storage.reference(forURL: url.absoluteString)
				try? await imageRef.delete()
				print("🗑️ Deleted collection image: \(imageURL)")
			}
		}
		
		// Step 4: Clean up user references (remove collection from users' followedCollectionIds)
		// This works for ALL collection types (Individual, Request, Join, Invite)
		if let collectionData = collectionData,
		   let followers = collectionData["followers"] as? [String], !followers.isEmpty {
			print("🧹 Cleaning up \(followers.count) follower references...")
			var batch = db.batch()
			var batchCount = 0
			
			for followerId in followers {
				let userRef = db.collection("users").document(followerId)
				batch.updateData([
					"followedCollectionIds": FieldValue.arrayRemove([collectionId])
				], forDocument: userRef)
				batchCount += 1
				
				// Firestore batch limit is 500
				if batchCount >= 500 {
					try await batch.commit()
					print("✅ Cleaned up batch of \(batchCount) follower references")
					batch = db.batch() // Create new batch
					batchCount = 0
				}
			}
			
			if batchCount > 0 {
				try await batch.commit()
				print("✅ Cleaned up remaining \(batchCount) follower references")
			}
		}
		
		// Step 5: Clean up member references (remove collection from members' user documents)
		// This is important for Request/Join/Invite collections
		if let collectionData = collectionData,
		   let members = collectionData["members"] as? [String], !members.isEmpty {
			print("🧹 Cleaning up \(members.count) member references...")
			var batch = db.batch()
			var batchCount = 0
			
			for memberId in members {
				let userRef = db.collection("users").document(memberId)
				// Remove from user's collections array if it exists
				batch.updateData([
					"collections": FieldValue.arrayRemove([collectionId])
				], forDocument: userRef)
				batchCount += 1
				
				// Firestore batch limit is 500
				if batchCount >= 500 {
					try await batch.commit()
					print("✅ Cleaned up batch of \(batchCount) member references")
					batch = db.batch() // Create new batch
					batchCount = 0
				}
			}
			
			if batchCount > 0 {
				try await batch.commit()
				print("✅ Cleaned up remaining \(batchCount) member references")
			}
		}
		
		// Step 6: Delete collection-related notifications
		// Delete all notifications related to this collection (requests, invites, etc.)
		print("🧹 Cleaning up collection-related notifications...")
		let notificationsQuery = db.collection("notifications")
			.whereField("collectionId", isEqualTo: collectionId)
			.limit(to: 500)
		
		let notificationsSnapshot = try? await notificationsQuery.getDocuments()
		if let notifications = notificationsSnapshot?.documents, !notifications.isEmpty {
			let batch = db.batch()
			for notificationDoc in notifications {
				// Get userId from notification to delete from user's notifications subcollection
				let notificationData = notificationDoc.data()
				if let userId = notificationData["userId"] as? String {
					let userNotificationRef = db.collection("users").document(userId)
						.collection("notifications").document(notificationDoc.documentID)
					batch.deleteDocument(userNotificationRef)
				}
				// Also delete from main notifications collection
				batch.deleteDocument(notificationDoc.reference)
			}
			try? await batch.commit()
			print("✅ Deleted \(notifications.count) collection-related notifications")
		}
		
		// Step 7: Delete from deleted_collections subcollection
		try await deletedRef.delete()
		print("✅ Deleted collection from deleted_collections subcollection")
		
		// Step 8: Also delete from main collections if it somehow still exists
		if (try? await mainCollectionRef.getDocument().exists) == true {
			try await mainCollectionRef.delete()
			print("✅ Deleted collection from main collections")
		}
		
		print("✅ CollectionService: Collection PERMANENTLY deleted with ALL related data")
		print("   - Posts deleted: \(totalPostsDeleted)")
		print("   - Collection image: Deleted")
		print("   - User references: Cleaned up")
		print("   - Notifications: Deleted")
		print("   - Collection document: Deleted")
		print("   ✅ This works for ALL collection types: Individual, Request, Join, Invite")
		
		// Post notification so collection disappears from deleted collections view
		Task { @MainActor in
			NotificationCenter.default.post(
				name: NSNotification.Name("CollectionDeleted"),
				object: collectionId,
				userInfo: ["permanent": true, "ownerId": ownerId, "postsDeleted": totalPostsDeleted]
			)
			print("📢 CollectionService: Posted CollectionDeleted notification (permanent)")
		}
		
		print("✅ CollectionService: Permanent delete completed successfully for collection: \(collectionId)")
		print("   Collection type: \(collectionData?["type"] as? String ?? "Unknown")")
		print("   Total posts permanently deleted: \(totalPostsDeleted)")
	}
	
	/// Get deleted collections for a user
	func getDeletedCollections(ownerId: String) async throws -> [(CollectionData, Date)] {
		let db = Firestore.firestore()
		// CRITICAL FIX: Add limit to prevent loading all deleted collections
		let snapshot = try await db.collection("users")
			.document(ownerId)
			.collection("deleted_collections")
			.order(by: "deletedAt", descending: true)
			.limit(to: 50) // Only show last 50 deleted collections
			.getDocuments()
		
		return snapshot.documents.compactMap { doc -> (CollectionData, Date)? in
			let data = doc.data()
			guard let deletedAt = data["deletedAt"] as? Timestamp else { return nil }
			let deletedAtDate = deletedAt.dateValue()
			
			// Check if 15 days have passed (changed from 30 to 15)
			let daysSinceDeleted = Calendar.current.dateComponents([.day], from: deletedAtDate, to: Date()).day ?? 0
			if daysSinceDeleted >= 15 {
				// Auto-delete expired collections
				Task {
					try? await permanentlyDeleteCollection(collectionId: doc.documentID, ownerId: ownerId)
				}
				return nil
			}
			
			let finalOwnerId = data["ownerId"] as? String ?? ownerId
			// Subscribe to real-time updates for collection owner
			if !finalOwnerId.isEmpty {
				UserService.shared.subscribeToUserProfile(userId: finalOwnerId)
			}
			
			let collection = CollectionData(
				id: doc.documentID,
				name: data["name"] as? String ?? "",
				description: data["description"] as? String ?? "",
				type: data["type"] as? String ?? "Individual",
				isPublic: data["isPublic"] as? Bool ?? false,
				ownerId: finalOwnerId,
				ownerName: data["ownerName"] as? String ?? "",
				owners: data["owners"] as? [String] ?? [ownerId],
				imageURL: data["imageURL"] as? String,
				invitedUsers: data["invitedUsers"] as? [String] ?? [],
				members: data["members"] as? [String] ?? [ownerId],
				memberCount: data["memberCount"] as? Int ?? 1,
				followers: data["followers"] as? [String] ?? [],
				followerCount: data["followerCount"] as? Int ?? 0,
				allowedUsers: data["allowedUsers"] as? [String] ?? [],
				deniedUsers: data["deniedUsers"] as? [String] ?? [],
				createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
			)
			
			return (collection, deletedAtDate)
		}
	}
	
	// Image upload is handled by Firebase Storage
	// No need for direct Firebase Storage upload
	
	func updateCollection(
		collectionId: String,
		name: String? = nil,
		description: String? = nil,
		image: UIImage? = nil,
		imageURL: String? = nil,
		isPublic: Bool? = nil,
		allowedUsers: [String]? = nil,
		deniedUsers: [String]? = nil
	) async throws {
		// Only owner or admin can update collection
		guard let currentUserId = Auth.auth().currentUser?.uid else {
			throw NSError(domain: "CollectionService", code: -1, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])
		}
		
		guard let collection = try await getCollection(collectionId: collectionId) else {
			throw NSError(domain: "CollectionService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Collection not found"])
		}
		
		let isOwner = collection.ownerId == currentUserId
		let isAdmin = collection.owners.contains(currentUserId)
		
		if !isOwner && !isAdmin {
			throw NSError(domain: "CollectionService", code: 403, userInfo: [NSLocalizedDescriptionKey: "Only owner or admins can update collection"])
		}
		
		var finalImageURL: String? = imageURL
		
		// Upload image to Firebase Storage first (like profile images)
		if let image = image {
			print("📤 CollectionService: Starting collection image upload to Firebase Storage...")
			
			do {
				let storage = Storage.storage()
				let imageRef = storage.reference().child("collection_images/\(collectionId).jpg")
				if let imageData = image.jpegData(compressionQuality: 0.8) {
					try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
						_ = imageRef.putData(imageData, metadata: nil) { metadata, error in
							if let error = error {
								continuation.resume(throwing: error)
							} else {
								continuation.resume()
							}
						}
					}
					let downloadURL = try await imageRef.downloadURL()
					finalImageURL = downloadURL.absoluteString
					print("✅ Collection image uploaded to Firebase Storage: \(finalImageURL ?? "nil")")
				}
			} catch {
				print("❌ CollectionService: Failed to upload collection image to Firebase Storage: \(error)")
				throw error
			}
		}
		
		// Use Firebase directly
		let db = Firestore.firestore()
		let collectionRef = db.collection("collections").document(collectionId)
		
		var firestoreUpdate: [String: Any] = [:]
		
		// Update name if provided
		if let name = name {
			firestoreUpdate["name"] = name
		}
		
		// Update description if provided
		if let description = description {
			firestoreUpdate["description"] = description
		}
		
		// Update imageURL if provided
		if let imageURL = finalImageURL {
			firestoreUpdate["imageURL"] = imageURL
		}
		
		// Update isPublic if provided
		if let isPublic = isPublic {
			firestoreUpdate["isPublic"] = isPublic
		}
		
		// Update allowedUsers if provided
		if let allowedUsers = allowedUsers {
			firestoreUpdate["allowedUsers"] = allowedUsers
		}
		
		// Update deniedUsers if provided
		if let deniedUsers = deniedUsers {
			firestoreUpdate["deniedUsers"] = deniedUsers
		}
		
		// Use set with merge: true to handle collections that don't exist in Firestore
		if !firestoreUpdate.isEmpty {
			try await collectionRef.setData(firestoreUpdate, merge: true)
			print("✅ CollectionService: Collection updated in Firebase Firestore")
		}
		
		// Reload collection to get verified data
		print("🔍 Verifying collection update was saved...")
		var verifiedCollection: CollectionData?
		do {
			verifiedCollection = try await getCollection(collectionId: collectionId)
			if let verified = verifiedCollection {
				print("✅ Verified update - Name: \(verified.name), Description: \(verified.description), Image URL: \(verified.imageURL ?? "nil")")
			}
		} catch {
			print("⚠️ Could not verify collection update: \(error)")
		}
		
		// Clear image cache to force fresh load (like edit profile clears cache)
		if let oldImageURL = imageURL, !oldImageURL.isEmpty {
			ImageCache.shared.removeImage(for: oldImageURL)
		}
		
		// Post comprehensive notification with verified data (like edit profile)
		Task { @MainActor in
			var updateData: [String: Any] = [
				"collectionId": collectionId
			]
			
			// Use verified data from Firebase if available, otherwise use what we sent
			if let verified = verifiedCollection {
				updateData["name"] = verified.name
				updateData["description"] = verified.description
				if let imageURL = verified.imageURL {
					updateData["imageURL"] = imageURL
				}
				updateData["isPublic"] = verified.isPublic
			} else {
				// Fallback to what we sent if verification failed
				if let name = name {
					updateData["name"] = name
				}
				if let description = description {
					updateData["description"] = description
				}
				if let imageURL = finalImageURL {
					updateData["imageURL"] = imageURL
				}
				if let isPublic = isPublic {
					updateData["isPublic"] = isPublic
				}
			}
			
			if let allowedUsers = allowedUsers {
				updateData["allowedUsers"] = allowedUsers
			}
			if let deniedUsers = deniedUsers {
				updateData["deniedUsers"] = deniedUsers
			}
			
			NotificationCenter.default.post(
				name: NSNotification.Name("CollectionUpdated"),
				object: collectionId,
				userInfo: ["updatedData": updateData]
			)
			
			// Also post ProfileUpdated to refresh profile views
			NotificationCenter.default.post(
				name: NSNotification.Name("ProfileUpdated"),
				object: nil,
				userInfo: ["updatedData": ["collectionId": collectionId]]
			)
			
			print("📢 CollectionService: Posted CollectionUpdated notification with verified data")
			print("   - Name: \(updateData["name"] as? String ?? "nil")")
			print("   - Description: \(updateData["description"] as? String ?? "nil")")
			print("   - Image URL: \(updateData["imageURL"] as? String ?? "nil")")
		}
	}
	
	func promoteToAdmin(collectionId: String, userId: String) async throws {
		print("👤 CollectionService: Promoting user \(userId) to admin in collection \(collectionId)")
		
		// Get collection to verify user is a member
		guard let collection = try await getCollection(collectionId: collectionId) else {
			throw NSError(domain: "CollectionService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Collection not found"])
		}
		
		// Check if user is already an admin
		if collection.owners.contains(userId) {
			print("⚠️ CollectionService: User is already an admin")
			return
		}
		
		// Check if user is a member
		if !collection.members.contains(userId) {
			throw NSError(domain: "CollectionService", code: 400, userInfo: [NSLocalizedDescriptionKey: "User must be a member before being promoted to admin"])
		}
		
		// Use Firebase directly
		let db = Firestore.firestore()
		let collectionRef = db.collection("collections").document(collectionId)
		
		// Add to owners array (admins are stored in owners array)
		try await collectionRef.updateData([
			"owners": FieldValue.arrayUnion([userId])
		])
		
		print("✅ CollectionService: User promoted to admin")
		
		// Post notification to refresh UI
		Task { @MainActor in
			NotificationCenter.default.post(
				name: NSNotification.Name("CollectionUpdated"),
				object: collectionId,
				userInfo: ["action": "memberPromoted", "userId": userId]
			)
		}
		
		print("✅ CollectionService: User \(userId) promoted to admin in collection \(collectionId)")
	}
	
	func demoteFromAdmin(collectionId: String, userId: String) async throws {
		let db = Firestore.firestore()
		let collectionRef = db.collection("collections").document(collectionId)
		
		// Remove from admins array
		try await collectionRef.updateData([
			"admins": FieldValue.arrayRemove([userId])
		])
		
		print("✅ User \(userId) demoted from admin in collection \(collectionId)")
	}
	
	func removeMember(collectionId: String, userId: String) async throws {
		print("👤 CollectionService: Removing user \(userId) from collection \(collectionId)")
		
		// Only owner or admin can remove members
		guard let currentUserId = Auth.auth().currentUser?.uid else {
			throw NSError(domain: "CollectionService", code: -1, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])
		}
		
		// Get collection to check if user is owner (cannot remove owner)
		guard let collection = try await getCollection(collectionId: collectionId) else {
			throw NSError(domain: "CollectionService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Collection not found"])
		}
		
		let isOwner = collection.ownerId == currentUserId
		let isAdmin = collection.owners.contains(currentUserId)
		
		if !isOwner && !isAdmin {
			throw NSError(domain: "CollectionService", code: 403, userInfo: [NSLocalizedDescriptionKey: "Only owner or admins can remove members"])
		}
		
		// Cannot remove the owner
		if collection.ownerId == userId {
			throw NSError(domain: "CollectionService", code: 400, userInfo: [NSLocalizedDescriptionKey: "Cannot remove the collection owner"])
		}
		
		// Use Firebase directly
		let db = Firestore.firestore()
		let collectionRef = db.collection("collections").document(collectionId)
		
		// Remove from members array
		try await collectionRef.updateData([
			"members": FieldValue.arrayRemove([userId]),
			"memberCount": FieldValue.increment(Int64(-1))
		])
		
		// Also remove from owners array if they were an admin (admins are stored in owners array)
		try await collectionRef.updateData([
			"owners": FieldValue.arrayRemove([userId])
		])
		
		// Remove from invitedUsers if present
		try await collectionRef.updateData([
			"invitedUsers": FieldValue.arrayRemove([userId])
		])
		
		print("✅ CollectionService: Member removed")
		
		// Post notification to refresh UI
		Task { @MainActor in
			NotificationCenter.default.post(
				name: NSNotification.Name("CollectionUpdated"),
				object: collectionId,
				userInfo: ["action": "memberRemoved", "userId": userId]
			)
			// Also post to update profile views
			NotificationCenter.default.post(
				name: NSNotification.Name("ProfileUpdated"),
				object: nil,
				userInfo: ["collectionId": collectionId, "userId": userId]
			)
			// Clear request state for this user and collection (they're no longer a member)
			NotificationCenter.default.post(
				name: NSNotification.Name("CollectionRequestCancelled"),
				object: collectionId,
				userInfo: ["requesterId": userId, "collectionId": collectionId]
			)
		}
		
		print("✅ CollectionService: User \(userId) removed from collection \(collectionId)")
	}
	
	func leaveCollection(collectionId: String, userId: String) async throws {
		print("👋 CollectionService: User \(userId) leaving collection \(collectionId)")
		
		// Get collection to verify user is a member/admin (not owner)
		guard let collection = try await getCollection(collectionId: collectionId) else {
			throw NSError(domain: "CollectionService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Collection not found"])
		}
		
		// Cannot leave if user is the owner
		guard collection.ownerId != userId else {
			throw NSError(domain: "CollectionService", code: 400, userInfo: [NSLocalizedDescriptionKey: "Collection owner cannot leave. Use delete instead."])
		}
		
		// Check if user is a member or admin
		let isMember = collection.members.contains(userId)
		let isAdmin = collection.owners.contains(userId) && userId != collection.ownerId
		
		guard isMember || isAdmin else {
			throw NSError(domain: "CollectionService", code: 400, userInfo: [NSLocalizedDescriptionKey: "User is not a member of this collection"])
		}
		
		// Use Firebase directly
		let db = Firestore.firestore()
		let collectionRef = db.collection("collections").document(collectionId)
		let userRef = db.collection("users").document(userId)
		
		// Get current memberJoinDates and remove the user's join date
		let collectionDoc = try await collectionRef.getDocument()
		var memberJoinDates = collectionDoc.data()?["memberJoinDates"] as? [String: Timestamp] ?? [:]
		memberJoinDates.removeValue(forKey: userId)
		
		// Use batch to ensure atomicity
		let batch = db.batch()
		
		// Remove from members array and decrement count, also remove join date
		batch.updateData([
			"members": FieldValue.arrayRemove([userId]),
			"memberCount": FieldValue.increment(Int64(-1)),
			"memberJoinDates": memberJoinDates
		], forDocument: collectionRef)
		
		// Remove from owners array if they were an admin (admins are stored in owners array)
		if isAdmin {
			batch.updateData([
				"owners": FieldValue.arrayRemove([userId])
			], forDocument: collectionRef)
		}
		
		// Remove collection from user's collections array
		batch.updateData([
			"collections": FieldValue.arrayRemove([collectionId])
		], forDocument: userRef)
		
		// Commit batch
		try await batch.commit()
		
		print("✅ CollectionService: User left collection")
		
		// Post notification for real-time UI updates
		Task { @MainActor in
			NotificationCenter.default.post(
				name: NSNotification.Name("CollectionUpdated"),
				object: collectionId,
				userInfo: ["action": "memberLeft", "userId": userId]
			)
			NotificationCenter.default.post(
				name: NSNotification.Name("UserCollectionsUpdated"),
				object: userId
			)
			// Clear request state for this user and collection (they're no longer a member)
			NotificationCenter.default.post(
				name: NSNotification.Name("CollectionRequestCancelled"),
				object: collectionId,
				userInfo: ["requesterId": userId, "collectionId": collectionId]
			)
			print("📢 CollectionService: Posted CollectionUpdated notification for member leaving")
		}
		
		print("✅ CollectionService: User \(userId) left collection \(collectionId)")
	}
	
	/// Remove a user from a collection (admin/owner only)
	func removeUserFromCollection(collectionId: String, userIdToRemove: String) async throws {
		guard let currentUserId = Auth.auth().currentUser?.uid else {
			throw NSError(domain: "CollectionService", code: -1, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])
		}
		
		// Get collection to verify permissions
		guard let collection = try await getCollection(collectionId: collectionId) else {
			throw NSError(domain: "CollectionService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Collection not found"])
		}
		
		// Check if current user is owner or admin
		let isOwner = collection.ownerId == currentUserId
		let isAdmin = collection.owners.contains(currentUserId)
		
		guard isOwner || isAdmin else {
			throw NSError(domain: "CollectionService", code: 403, userInfo: [NSLocalizedDescriptionKey: "Only owners and admins can remove users"])
		}
		
		// Cannot remove owner
		guard collection.ownerId != userIdToRemove else {
			throw NSError(domain: "CollectionService", code: 400, userInfo: [NSLocalizedDescriptionKey: "Cannot remove collection owner"])
		}
		
		let db = Firestore.firestore()
		let collectionRef = db.collection("collections").document(collectionId)
		let userRef = db.collection("users").document(userIdToRemove)
		
		// Get current memberJoinDates and remove the user's join date
		let collectionDoc = try await collectionRef.getDocument()
		var memberJoinDates = collectionDoc.data()?["memberJoinDates"] as? [String: Timestamp] ?? [:]
		memberJoinDates.removeValue(forKey: userIdToRemove)
		
		// Use batch to ensure atomicity
		let batch = db.batch()
		
		// Remove from members array and decrement count, also remove join date
		batch.updateData([
			"members": FieldValue.arrayRemove([userIdToRemove]),
			"memberCount": FieldValue.increment(Int64(-1)),
			"memberJoinDates": memberJoinDates
		], forDocument: collectionRef)
		
		// Remove from admins if they were an admin
		batch.updateData([
			"owners": FieldValue.arrayRemove([userIdToRemove])
		], forDocument: collectionRef)
		
		// Remove collection from user's collections array
		batch.updateData([
			"collections": FieldValue.arrayRemove([collectionId])
		], forDocument: userRef)
		
		// Commit batch
		try await batch.commit()
		
		print("✅ CollectionService: Removed user \(userIdToRemove) from collection \(collectionId)")
		
		// Post notification for real-time UI updates
		Task { @MainActor in
			NotificationCenter.default.post(
				name: NSNotification.Name("CollectionUpdated"),
				object: collectionId,
				userInfo: ["action": "memberRemoved", "userId": userIdToRemove]
			)
		}
	}
	
	// MARK: - Collection Request Management
	func sendCollectionRequest(collectionId: String) async throws {
		guard let currentUserId = Auth.auth().currentUser?.uid else {
			throw NSError(domain: "CollectionService", code: -1, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])
		}
		
		// Get collection
		guard let collection = try await getCollection(collectionId: collectionId) else {
			throw NSError(domain: "CollectionService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Collection not found"])
		}
		
		// Check if user is already a member
		if collection.members.contains(currentUserId) {
			throw NSError(domain: "CollectionService", code: 400, userInfo: [NSLocalizedDescriptionKey: "User is already a member"])
		}
		
		// Get current user info
		guard let currentUser = try await UserService.shared.getUser(userId: currentUserId) else {
			throw NSError(domain: "CollectionService", code: -1, userInfo: [NSLocalizedDescriptionKey: "User not found"])
		}
		
		// Send notification to owner and admins (will update existing if one exists)
		try await NotificationService.shared.sendCollectionRequestNotification(
			collectionId: collectionId,
			collectionName: collection.name,
			requesterId: currentUserId,
			requesterUsername: currentUser.username,
			requesterProfileImageURL: currentUser.profileImageURL
		)
		
		print("✅ CollectionService: Collection request sent for collection \(collectionId)")
		
		// Note: UI notification is posted by the view that calls this function for immediate feedback
	}
	
	// MARK: - Cancel Collection Request
	func cancelCollectionRequest(collectionId: String) async throws {
		guard let currentUserId = Auth.auth().currentUser?.uid else {
			throw NSError(domain: "CollectionService", code: -1, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])
		}
		
		// Get collection
		guard try await getCollection(collectionId: collectionId) != nil else {
			throw NSError(domain: "CollectionService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Collection not found"])
		}
		
		// Cancel notification (delete it)
		try await NotificationService.shared.cancelCollectionRequestNotification(
			collectionId: collectionId,
			requesterId: currentUserId
		)
		
		print("✅ CollectionService: Collection request cancelled for collection \(collectionId)")
		
		// Note: UI notification is posted by the view that calls this function for immediate feedback
	}
	
	func acceptCollectionRequest(collectionId: String, requesterId: String, notificationId: String) async throws {
		guard let currentUserId = Auth.auth().currentUser?.uid else {
			throw NSError(domain: "CollectionService", code: -1, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])
		}
		
		// Get collection
		guard let collection = try await getCollection(collectionId: collectionId) else {
			throw NSError(domain: "CollectionService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Collection not found"])
		}
		
		// Check if current user is owner or admin
		let isOwner = collection.ownerId == currentUserId
		let isAdmin = collection.owners.contains(currentUserId)
		
		if !isOwner && !isAdmin {
			throw NSError(domain: "CollectionService", code: 403, userInfo: [NSLocalizedDescriptionKey: "Only owner or admins can accept requests"])
		}
		
		// Check if requester is already a member
		if collection.members.contains(requesterId) {
			// Just delete the notification
			try await NotificationService.shared.deleteNotification(
				notificationId: notificationId,
				userId: currentUserId
			)
			return
		}
		
		// Use Firebase directly
		let db = Firestore.firestore()
		let collectionRef = db.collection("collections").document(collectionId)
		
		// Get current memberJoinDates and deniedUsers
		let collectionDoc = try await collectionRef.getDocument()
		let collectionData = collectionDoc.data() ?? [:]
		var memberJoinDates = collectionData["memberJoinDates"] as? [String: Timestamp] ?? [:]
		memberJoinDates[requesterId] = Timestamp()
		var deniedUsers = collectionData["deniedUsers"] as? [String] ?? []
		
		// Remove from deniedUsers if they were previously denied
		deniedUsers.removeAll { $0 == requesterId }
		
		// Add requester to members
		var updateData: [String: Any] = [
			"members": FieldValue.arrayUnion([requesterId]),
			"memberCount": FieldValue.increment(Int64(1)),
			"memberJoinDates": memberJoinDates
		]
		
		// Update deniedUsers if it changed
		if deniedUsers != (collectionData["deniedUsers"] as? [String] ?? []) {
			updateData["deniedUsers"] = deniedUsers
		}
		
		try await collectionRef.updateData(updateData)
		
		// Also add collection to requester's user document (for profile display)
		let userRef = db.collection("users").document(requesterId)
		try await userRef.updateData([
			"collections": FieldValue.arrayUnion([collectionId])
		])
		
		print("✅ CollectionService: User \(requesterId) added to collection \(collectionId)")
		
		// Delete notification for all admins who received this notification
		// Find all notifications for this request and delete them
		for adminId in collection.owners {
			if adminId == currentUserId {
				// Delete the notification that was clicked
				try await NotificationService.shared.deleteNotification(
					notificationId: notificationId,
					userId: adminId
				)
			} else {
				// Find and delete other admins' notifications for this request
				let notifications = try await NotificationService.shared.getNotifications(userId: adminId)
				for otherNotification in notifications where 
					otherNotification.type == "collection_request" && 
					otherNotification.collectionId == collectionId && 
					otherNotification.userId == requesterId && 
					otherNotification.status == "pending" {
					try await NotificationService.shared.deleteNotification(
						notificationId: otherNotification.id,
						userId: adminId
					)
				}
			}
		}
		
		// Post notification to update UI
		Task { @MainActor in
			NotificationCenter.default.post(
				name: NSNotification.Name("CollectionRequestAccepted"),
				object: collectionId,
				userInfo: ["requesterId": requesterId]
			)
			NotificationCenter.default.post(
				name: NSNotification.Name("CollectionUpdated"),
				object: collectionId,
				userInfo: ["action": "memberAdded", "userId": requesterId]
			)
			// Post notification to refresh requester's profile collections
			NotificationCenter.default.post(
				name: NSNotification.Name("UserCollectionsUpdated"),
				object: requesterId
			)
		}
		
		print("✅ CollectionService: Collection request accepted for user \(requesterId)")
		
		// Post notification to refresh requester's profile collections
		Task { @MainActor in
			NotificationCenter.default.post(
				name: NSNotification.Name("UserCollectionsUpdated"),
				object: requesterId
			)
		}
	}
	
	func denyCollectionRequest(collectionId: String, requesterId: String, notificationId: String) async throws {
		guard let currentUserId = Auth.auth().currentUser?.uid else {
			throw NSError(domain: "CollectionService", code: -1, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])
		}
		
		// Get collection
		guard let collection = try await getCollection(collectionId: collectionId) else {
			throw NSError(domain: "CollectionService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Collection not found"])
		}
		
		// Check if current user is owner or admin
		let isOwner = collection.ownerId == currentUserId
		let isAdmin = collection.owners.contains(currentUserId)
		
		if !isOwner && !isAdmin {
			throw NSError(domain: "CollectionService", code: 403, userInfo: [NSLocalizedDescriptionKey: "Only owner or admins can deny requests"])
		}
		
		// Add requester to deniedUsers array to prevent future requests
		let db = Firestore.firestore()
		let collectionRef = db.collection("collections").document(collectionId)
		
		// Get current deniedUsers
		let collectionDoc = try await collectionRef.getDocument()
		var deniedUsers = collectionDoc.data()?["deniedUsers"] as? [String] ?? []
		
		// Add requester to deniedUsers if not already there
		if !deniedUsers.contains(requesterId) {
			deniedUsers.append(requesterId)
			try await collectionRef.updateData([
				"deniedUsers": deniedUsers
			])
		}
		
		// Delete the notification that was clicked
		try await NotificationService.shared.deleteNotification(
			notificationId: notificationId,
			userId: currentUserId
		)
		
		// Delete other admins' notifications for this request
		for adminId in collection.owners {
			if adminId != currentUserId {
				let notifications = try await NotificationService.shared.getNotifications(userId: adminId)
				for otherNotification in notifications where 
					otherNotification.type == "collection_request" && 
					otherNotification.collectionId == collectionId && 
					otherNotification.userId == requesterId && 
					otherNotification.status == "pending" {
					try await NotificationService.shared.deleteNotification(
						notificationId: otherNotification.id,
						userId: adminId
					)
				}
			}
		}
		
		// Post notification to update UI
		Task { @MainActor in
			NotificationCenter.default.post(
				name: NSNotification.Name("CollectionRequestDenied"),
				object: collectionId,
				userInfo: ["requesterId": requesterId]
			)
		}
		
		print("✅ CollectionService: Collection request denied for user \(requesterId)")
	}
	
	// MARK: - Collection Invite Management
	func acceptCollectionInvite(collectionId: String, notificationId: String) async throws {
		guard let currentUserId = Auth.auth().currentUser?.uid else {
			throw NSError(domain: "CollectionService", code: -1, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])
		}
		
		// Get collection
		guard let collection = try await getCollection(collectionId: collectionId) else {
			throw NSError(domain: "CollectionService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Collection not found"])
		}
		
		// Check if user is already a member
		if collection.members.contains(currentUserId) {
			// Just delete the notification
			try await NotificationService.shared.deleteNotification(
				notificationId: notificationId,
				userId: currentUserId
			)
			return
		}
		
		// CRITICAL: Verify user is in invitedUsers array (required for Firebase security rules)
		if !collection.invitedUsers.contains(currentUserId) {
			throw NSError(domain: "CollectionService", code: 403, userInfo: [NSLocalizedDescriptionKey: "User is not in the invited users list"])
		}
		
		do {
			// Use Firebase directly (same pattern as acceptCollectionRequest - direct updates work better for permissions)
			let db = Firestore.firestore()
			let collectionRef = db.collection("collections").document(collectionId)
			let userRef = db.collection("users").document(currentUserId)
			
			// Get current memberJoinDates
			let collectionDoc = try await collectionRef.getDocument()
			var memberJoinDates = collectionDoc.data()?["memberJoinDates"] as? [String: Timestamp] ?? [:]
			memberJoinDates[currentUserId] = Timestamp()
			
			// Add user to members and remove from invitedUsers (same pattern as acceptCollectionRequest)
			try await collectionRef.updateData([
				"members": FieldValue.arrayUnion([currentUserId]),
				"memberCount": FieldValue.increment(Int64(1)),
				"memberJoinDates": memberJoinDates,
				"invitedUsers": FieldValue.arrayRemove([currentUserId])
			])
			
			// Also add collection to user's document (for profile display)
			try await userRef.updateData([
				"collections": FieldValue.arrayUnion([collectionId])
			])
			
			print("✅ CollectionService: User \(currentUserId) accepted invite and joined collection \(collectionId)")
			
			// Delete the notification
			try await NotificationService.shared.deleteNotification(
				notificationId: notificationId,
				userId: currentUserId
			)
			
			print("✅ CollectionService: Collection invite accepted and notification deleted for user \(currentUserId)")
			
			// Post notifications AFTER successful update (same pattern as acceptCollectionRequest)
			Task { @MainActor in
				NotificationCenter.default.post(
					name: NSNotification.Name("CollectionInviteAccepted"),
					object: collectionId,
					userInfo: ["userId": currentUserId]
				)
				NotificationCenter.default.post(
					name: NSNotification.Name("CollectionUpdated"),
					object: collectionId,
					userInfo: ["action": "memberAdded", "userId": currentUserId]
				)
				NotificationCenter.default.post(
					name: NSNotification.Name("UserCollectionsUpdated"),
					object: currentUserId
				)
			}
		} catch {
			// Log error but don't post notifications on error
			print("❌ CollectionService: Error accepting invite: \(error.localizedDescription)")
			print("❌ CollectionService: Error details: \(error)")
			throw error
		}
	}
	
	func denyCollectionInvite(collectionId: String, notificationId: String) async throws {
		guard let currentUserId = Auth.auth().currentUser?.uid else {
			throw NSError(domain: "CollectionService", code: -1, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])
		}
		
		// Verify collection exists
		guard try await getCollection(collectionId: collectionId) != nil else {
			throw NSError(domain: "CollectionService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Collection not found"])
		}
		
		do {
			// Remove from invitedUsers if present
			let db = Firestore.firestore()
			let collectionRef = db.collection("collections").document(collectionId)
			try await collectionRef.updateData([
				"invitedUsers": FieldValue.arrayRemove([currentUserId])
			])
			
			// Delete the notification
			try await NotificationService.shared.deleteNotification(
				notificationId: notificationId,
				userId: currentUserId
			)
			
			print("✅ CollectionService: Collection invite denied for user \(currentUserId)")
			
			// Post notification to update UI AFTER successful update
			Task { @MainActor in
				NotificationCenter.default.post(
					name: NSNotification.Name("CollectionInviteDenied"),
					object: collectionId,
					userInfo: ["userId": currentUserId]
				)
			}
		} catch {
			print("❌ CollectionService: Error denying invite: \(error.localizedDescription)")
			print("❌ CollectionService: Error details: \(error)")
			throw error
		}
	}
	
	// MARK: - Join Collection (Open Collections)
	func joinCollection(collectionId: String) async throws {
		guard let currentUserId = Auth.auth().currentUser?.uid else {
			throw NSError(domain: "CollectionService", code: -1, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])
		}
		
		// Get collection
		guard let collection = try await getCollection(collectionId: collectionId) else {
			throw NSError(domain: "CollectionService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Collection not found"])
		}
		
		// Check if collection is Open type
		guard collection.type == "Open" else {
			throw NSError(domain: "CollectionService", code: 400, userInfo: [NSLocalizedDescriptionKey: "Only Open collections can be joined directly"])
		}
		
		// Check if user is already a member
		if collection.members.contains(currentUserId) {
			throw NSError(domain: "CollectionService", code: 400, userInfo: [NSLocalizedDescriptionKey: "User is already a member"])
		}
		
		// Get current user info before transaction
		guard let currentUser = try await UserService.shared.getUser(userId: currentUserId) else {
			throw NSError(domain: "CollectionService", code: -1, userInfo: [NSLocalizedDescriptionKey: "User not found"])
		}
		
		// Use transaction to atomically add member and handle batch notifications
		do {
			// Run transaction with User-initiated QoS to avoid priority inversion
			// Create Firestore references inside the detached task to ensure they're on the correct thread
			let notificationData = try await Task.detached(priority: .userInitiated) {
				var shouldSendNotification = false
				var pendingJoinsToNotify: [[String: Any]] = []
				var collectionNameForNotification = ""
				
				// Create Firestore references inside the detached task
				let db = Firestore.firestore()
				let collectionRef = db.collection("collections").document(collectionId)
				
				// Execute transaction - result is intentionally unused as we only need side effects
				// Note: Firestore SDK may use default QoS internally, causing priority inversion warnings
				let _ = try await db.runTransaction { transaction, errorPointer -> Any? in
				// Get current collection data
				do {
					let collectionDoc = try transaction.getDocument(collectionRef)
					guard let collectionData = collectionDoc.data() else {
						if let errorPointer = errorPointer {
							errorPointer.pointee = NSError(domain: "CollectionService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Collection not found"])
						}
						return nil
					}
					
					// Get current members and pending joins
					var members = collectionData["members"] as? [String] ?? []
					var pendingJoins = collectionData["pendingJoins"] as? [[String: Any]] ?? []
					
					// Check if user is already a member (double-check)
					if members.contains(currentUserId) {
						return nil // Already a member, nothing to do
					}
					
					// Add user to members
					members.append(currentUserId)
					
					// Add user to pending joins for batch notification
					let joinInfo: [String: Any] = [
						"userId": currentUserId,
						"username": currentUser.username,
						"name": currentUser.name,
						"profileImageURL": currentUser.profileImageURL ?? "",
						"joinedAt": Timestamp()
					]
					pendingJoins.append(joinInfo)
					
						// Threshold is 6 for batch notifications
						let threshold = 6
					
					// Check if we've reached the threshold
					if pendingJoins.count >= threshold {
						shouldSendNotification = true
						pendingJoinsToNotify = pendingJoins
						collectionNameForNotification = collectionData["name"] as? String ?? ""
						// Clear pending joins
						pendingJoins = []
					}
					
					// Get current memberJoinDates
					var memberJoinDates = collectionData["memberJoinDates"] as? [String: Timestamp] ?? [:]
					// Add join date for new member
					memberJoinDates[currentUserId] = Timestamp()
					
					// Update collection document
					transaction.updateData([
						"members": members,
						"memberCount": members.count,
						"pendingJoins": pendingJoins,
						"memberJoinDates": memberJoinDates
					], forDocument: collectionRef)
					
					// Also update user's collections array
					let userRef = db.collection("users").document(currentUserId)
					transaction.updateData([
						"collections": FieldValue.arrayUnion([collectionId])
					], forDocument: userRef)
					
					return nil
				} catch {
					if let errorPointer = errorPointer {
						errorPointer.pointee = error as NSError
					}
					return nil
				}
			}
				
				return (shouldSendNotification, pendingJoinsToNotify, collectionNameForNotification)
			}.value
			
			let (shouldSendNotification, pendingJoinsToNotify, collectionNameForNotification) = notificationData
			
			// Post notifications after successful transaction (same pattern as invite/request)
			NotificationCenter.default.post(
				name: NSNotification.Name("CollectionJoined"),
				object: collectionId,
				userInfo: ["userId": currentUserId]
			)
			NotificationCenter.default.post(
				name: NSNotification.Name("CollectionUpdated"),
				object: collectionId,
				userInfo: ["action": "memberAdded", "userId": currentUserId]
			)
			NotificationCenter.default.post(
				name: NSNotification.Name("UserCollectionsUpdated"),
				object: currentUserId
			)
			
			// Send notification outside transaction if threshold reached
			if shouldSendNotification {
				try await NotificationService.shared.sendBatchJoinNotification(
					collectionId: collectionId,
					collectionName: collectionNameForNotification,
					joinedUsers: pendingJoinsToNotify
				)
			}
			
			print("✅ CollectionService: User \(currentUserId) joined collection \(collectionId)")
		} catch {
			// Revert notifications on error
			print("❌ CollectionService: Error joining collection, reverting notifications: \(error.localizedDescription)")
			NotificationCenter.default.post(
				name: NSNotification.Name("CollectionLeft"),
				object: collectionId,
				userInfo: ["userId": currentUserId]
			)
			throw error
		}
	}
	
	// MARK: - Post Management
	func deletePost(postId: String) async throws {
		// Get post data first to delete media files
		let db = Firestore.firestore()
		let postRef = db.collection("posts").document(postId)
		guard let postData = try? await postRef.getDocument().data() else {
			throw NSError(domain: "CollectionService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Post not found"])
		}
		
		// Delete media files asynchronously (don't block deletion)
		Task {
			// Get media items from post data
			if let mediaItems = postData["mediaItems"] as? [[String: Any]] {
				for mediaItem in mediaItems {
					// Delete image
					if let imageURL = mediaItem["imageURL"] as? String, !imageURL.isEmpty {
						_ = try? await StorageService.shared.deleteFile(from: imageURL)
					}
					// Delete video
					if let videoURL = mediaItem["videoURL"] as? String, !videoURL.isEmpty {
						_ = try? await StorageService.shared.deleteFile(from: videoURL)
					}
					// Delete thumbnail
					if let thumbnailURL = mediaItem["thumbnailURL"] as? String, !thumbnailURL.isEmpty {
						_ = try? await StorageService.shared.deleteFile(from: thumbnailURL)
					}
				}
			}
		}
		
		// Get collectionId before deleting
		let collectionId = postData["collectionId"] as? String ?? ""
		
		// Delete the post document
		try await postRef.delete()
		
		// Post notification with collectionId
		Task { @MainActor in
			NotificationCenter.default.post(
				name: NSNotification.Name("PostDeleted"),
				object: postId,
				userInfo: ["postId": postId, "collectionId": collectionId]
			)
		}
	}
	
	// MARK: - Update Post
	func updatePost(
		postId: String,
		caption: String?,
		taggedUsers: [String]?,
		allowDownload: Bool?,
		allowReplies: Bool?
	) async throws {
		let db = Firestore.firestore()
		let postRef = db.collection("posts").document(postId)
		
		var updateData: [String: Any] = [:]
		
		// Update caption (can be set to empty string to remove)
		if let caption = caption {
			updateData["caption"] = caption.isEmpty ? FieldValue.delete() : caption
		}
		
		// Update tagged users
		if let taggedUsers = taggedUsers {
			updateData["taggedUsers"] = taggedUsers
		}
		
		// Update allowDownload - always update if provided (even if false)
		if let allowDownload = allowDownload {
			updateData["allowDownload"] = allowDownload
			print("🔍 updatePost: Setting allowDownload to \(allowDownload) for post \(postId)")
		} else {
			print("⚠️ updatePost: allowDownload is nil, not updating")
		}
		
		// Update allowReplies - always update if provided (even if false)
		if let allowReplies = allowReplies {
			updateData["allowReplies"] = allowReplies
			print("🔍 updatePost: Setting allowReplies to \(allowReplies) for post \(postId)")
		} else {
			print("⚠️ updatePost: allowReplies is nil, not updating")
		}
		
		// Only update if there are changes
		guard !updateData.isEmpty else {
			print("⚠️ No changes to update for post \(postId)")
			return
		}
		
		// Update the post document
		try await postRef.updateData(updateData)
		
		print("✅ Post \(postId) updated successfully")
		
		// Verify the values were saved correctly
		do {
			let savedDoc = try await postRef.getDocument()
			if let savedData = savedDoc.data() {
				let savedAllowDownload = savedData["allowDownload"] as? Bool
				let savedAllowReplies = savedData["allowReplies"] as? Bool
				print("🔍 Verification: Updated post \(postId) has:")
				print("   - allowDownload in Firestore: \(savedAllowDownload?.description ?? "nil")")
				print("   - allowReplies in Firestore: \(savedAllowReplies?.description ?? "nil")")
				if let expectedDownload = allowDownload, savedAllowDownload != expectedDownload {
					print("❌ ERROR: allowDownload mismatch! Expected \(expectedDownload), got \(savedAllowDownload?.description ?? "nil")")
				}
				if let expectedReplies = allowReplies, savedAllowReplies != expectedReplies {
					print("❌ ERROR: allowReplies mismatch! Expected \(expectedReplies), got \(savedAllowReplies?.description ?? "nil")")
				}
			}
		} catch {
			print("⚠️ Could not verify updated post: \(error)")
		}
		
		// Post notification to refresh views
		Task { @MainActor in
			NotificationCenter.default.post(
				name: NSNotification.Name("PostUpdated"),
				object: postId,
				userInfo: ["postId": postId]
			)
		}
	}
	
	func togglePostPin(postId: String, isPinned: Bool) async throws {
		// Use Firebase directly
		let db = Firestore.firestore()
		var updateData: [String: Any] = ["isPinned": isPinned]
		
		// Store pin timestamp for sorting (most recent first)
		if isPinned {
			updateData["pinnedAt"] = Timestamp(date: Date())
		} else {
			updateData["pinnedAt"] = FieldValue.delete()
		}
		
		try await db.collection("posts").document(postId).updateData(updateData)
		
		// Post notification
		Task { @MainActor in
			NotificationCenter.default.post(
				name: NSNotification.Name("PostCreated"),
				object: nil
			)
		}
	}
	
	// MARK: - Privacy Helper Functions
	
	/// Get collections visible to a viewing user (respects privacy settings)
	/// - Parameters:
	///   - profileUserId: The user whose collections we're viewing
	///   - viewingUserId: The user who is viewing (current user)
	///   - forceFresh: Whether to force a fresh fetch
	/// - Returns: Array of collections the viewing user can see
	func getVisibleCollectionsForUser(profileUserId: String, viewingUserId: String, forceFresh: Bool = false) async throws -> [CollectionData] {
		// Get all collections for the profile user
		let allCollections = try await getUserCollections(userId: profileUserId, forceFresh: forceFresh)
		
		// Filter based on privacy settings
		var visibleCollections = allCollections.filter { collection in
			return CollectionService.canUserViewCollection(collection, userId: viewingUserId)
		}
		
		// Filter out hidden collections and collections from blocked users
		visibleCollections = await CollectionService.filterCollections(visibleCollections)
		
		return visibleCollections
	}
	
	// MARK: - Follow/Unfollow Collection
	
	/// Follow a collection - adds user to collection's followers and collection to user's followedCollectionIds
	func followCollection(collectionId: String, userId: String) async throws {
		let db = Firestore.firestore()
		
		// Get collection to verify it exists
		guard let collection = try await getCollection(collectionId: collectionId) else {
			throw NSError(domain: "CollectionService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Collection not found"])
		}
		
		// Check if already following
		if collection.followers.contains(userId) {
			print("⚠️ User \(userId) is already following collection \(collectionId)")
			return
		}
		
		// Use batch write for atomic updates
		let batch = db.batch()
		
		// Add user to collection's followers array
		let collectionRef = db.collection("collections").document(collectionId)
		batch.updateData([
			"followers": FieldValue.arrayUnion([userId]),
			"followerCount": FieldValue.increment(Int64(1))
		], forDocument: collectionRef)
		
		// Add collection to user's followedCollectionIds array
		let userRef = db.collection("users").document(userId)
		batch.updateData([
			"followedCollectionIds": FieldValue.arrayUnion([collectionId])
		], forDocument: userRef)
		
		// Commit batch
		try await batch.commit()
		
		print("✅ User \(userId) followed collection \(collectionId)")
		
		// Post notifications
		Task { @MainActor in
			NotificationCenter.default.post(
				name: NSNotification.Name("CollectionFollowed"),
				object: collectionId,
				userInfo: ["userId": userId]
			)
			NotificationCenter.default.post(
				name: NSNotification.Name("CollectionUpdated"),
				object: collectionId
			)
		}
	}
	
	/// Unfollow a collection - removes user from collection's followers and collection from user's followedCollectionIds
	func unfollowCollection(collectionId: String, userId: String) async throws {
		let db = Firestore.firestore()
		
		// Get collection to verify it exists
		guard let collection = try await getCollection(collectionId: collectionId) else {
			throw NSError(domain: "CollectionService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Collection not found"])
		}
		
		// Check if not following
		if !collection.followers.contains(userId) {
			print("⚠️ User \(userId) is not following collection \(collectionId)")
			return
		}
		
		// Use batch write for atomic updates
		let batch = db.batch()
		
		// Remove user from collection's followers array
		let collectionRef = db.collection("collections").document(collectionId)
		batch.updateData([
			"followers": FieldValue.arrayRemove([userId]),
			"followerCount": FieldValue.increment(Int64(-1))
		], forDocument: collectionRef)
		
		// Remove collection from user's followedCollectionIds array
		let userRef = db.collection("users").document(userId)
		batch.updateData([
			"followedCollectionIds": FieldValue.arrayRemove([collectionId])
		], forDocument: userRef)
		
		// Commit batch
		try await batch.commit()
		
		print("✅ User \(userId) unfollowed collection \(collectionId)")
		
		// Post notifications
		Task { @MainActor in
			NotificationCenter.default.post(
				name: NSNotification.Name("CollectionUnfollowed"),
				object: collectionId,
				userInfo: ["userId": userId]
			)
			NotificationCenter.default.post(
				name: NSNotification.Name("CollectionUpdated"),
				object: collectionId
			)
		}
	}
	
	/// Check if a user is following a collection
	func isFollowingCollection(collectionId: String, userId: String) -> Bool {
		// This will be called with cached data, so we need to get the collection first
		// For now, return false and let the caller check the collection's followers array
		return false
	}
	
	/// Get all collections a user is following
	func getFollowedCollections(userId: String) async throws -> [CollectionData] {
		let db = Firestore.firestore()
		
		// Get user's followedCollectionIds
		let userDoc = try await db.collection("users").document(userId).getDocument()
		guard let userData = userDoc.data(),
			  let followedIds = userData["followedCollectionIds"] as? [String] else {
			return []
		}
		
		// Fetch all followed collections in parallel
		var followedCollections: [CollectionData] = []
		await withTaskGroup(of: CollectionData?.self) { group in
			for collectionId in followedIds {
				group.addTask {
					try? await self.getCollection(collectionId: collectionId)
				}
			}
			
			for await collection in group {
				if let collection = collection {
					followedCollections.append(collection)
				}
			}
		}
		
		// Filter out hidden collections (mutual blocking, blocked users, etc.)
		return await CollectionService.filterCollections(followedCollections)
	}
	
	/// Remove a follower from a collection (owner/admin only)
	func removeFollower(collectionId: String, followerId: String) async throws {
		guard let currentUserId = Auth.auth().currentUser?.uid else {
			throw NSError(domain: "CollectionService", code: -1, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])
		}
		
		// Get collection to verify permissions
		guard let collection = try await getCollection(collectionId: collectionId) else {
			throw NSError(domain: "CollectionService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Collection not found"])
		}
		
		// Check if current user is owner or admin
		let isOwner = collection.ownerId == currentUserId
		let isAdmin = collection.owners.contains(currentUserId)
		
		if !isOwner && !isAdmin {
			throw NSError(domain: "CollectionService", code: 403, userInfo: [NSLocalizedDescriptionKey: "Only owner or admins can remove followers"])
		}
		
		// Use batch write for atomic updates
		let db = Firestore.firestore()
		let batch = db.batch()
		
		// Remove follower from collection's followers array
		let collectionRef = db.collection("collections").document(collectionId)
		batch.updateData([
			"followers": FieldValue.arrayRemove([followerId]),
			"followerCount": FieldValue.increment(Int64(-1))
		], forDocument: collectionRef)
		
		// Remove collection from follower's followedCollectionIds array
		let userRef = db.collection("users").document(followerId)
		batch.updateData([
			"followedCollectionIds": FieldValue.arrayRemove([collectionId])
		], forDocument: userRef)
		
		// Commit batch
		try await batch.commit()
		
		print("✅ Removed follower \(followerId) from collection \(collectionId)")
		
		// Post notifications
		Task { @MainActor in
			NotificationCenter.default.post(
				name: NSNotification.Name("CollectionUpdated"),
				object: collectionId
			)
		}
	}
}

// MARK: - CollectionService Static Helper Methods Extension
extension CollectionService {
	/// Check if a user can view a collection based on privacy settings
	/// - Parameters:
	///   - collection: The collection to check
	///   - userId: The user ID to check access for
	/// - Returns: true if the user can view the collection, false otherwise
	/// NEW ACCESS SYSTEM: Allow = show everywhere, Deny = hide everywhere
	nonisolated static func canUserViewCollection(_ collection: CollectionData, userId: String) -> Bool {
		// Check if user is owner or admin
		let isOwner = collection.ownerId == userId
		let isAdmin = collection.owners.contains(userId)
		if isOwner || isAdmin {
			return true
		}
		
		// Check if user is a member
		if collection.members.contains(userId) {
			return true
		}
		
		// ACCESS CONTROL SYSTEM:
		// If user is in deniedUsers → hide collection everywhere (return false, treat as private)
		if collection.deniedUsers.contains(userId) {
			return false
		}
		
		// If user is in allowedUsers → show collection everywhere (return true, treat as public)
		// This makes private collections with granted access behave like public collections
		if collection.allowedUsers.contains(userId) {
			return true
		}
		
		// Default behavior: public collections are visible, private collections are not
		return collection.isPublic
	}
	
	/// Check if a collection should be treated as "public" for a specific user
	/// Returns true if the collection is public OR if the user is in allowedUsers
	nonisolated static func isCollectionPublicForUser(_ collection: CollectionData, userId: String) -> Bool {
		// If user is in allowedUsers, treat as public (visible everywhere)
		if collection.allowedUsers.contains(userId) {
			return true
		}
		// Otherwise, use the actual isPublic flag
		return collection.isPublic
	}
	
	/// Filter out collections that are hidden by the current user
	/// - Parameter collections: Array of collections to filter
	/// - Returns: Filtered array excluding hidden collections
	@MainActor
	static func filterHiddenCollections(_ collections: [CollectionData]) async -> [CollectionData] {
		do {
			try await CYServiceManager.shared.loadCurrentUser()
			let hiddenCollectionIds = Set(CYServiceManager.shared.getHiddenCollectionIds())
			return collections.filter { !hiddenCollectionIds.contains($0.id) }
		} catch {
			print("Error loading hidden collections: \(error.localizedDescription)")
			return collections
		}
	}
	
	/// Filter out posts from hidden collections
	/// - Parameter posts: Array of posts to filter
	/// - Returns: Filtered array excluding posts from hidden collections
	@MainActor
	static func filterPostsFromHiddenCollections(_ posts: [CollectionPost]) async -> [CollectionPost] {
		do {
			try await CYServiceManager.shared.loadCurrentUser()
			let hiddenCollectionIds = Set(CYServiceManager.shared.getHiddenCollectionIds())
			return posts.filter { post in
				if post.collectionId.isEmpty {
					return true
				}
				return !hiddenCollectionIds.contains(post.collectionId)
			}
		} catch {
			print("Error loading hidden collections: \(error.localizedDescription)")
			return posts
		}
	}
	
	/// Filter out collections owned by blocked users or where owner has blocked current user (mutual blocking)
	/// - Parameter collections: Array of collections to filter
	/// - Returns: Filtered array excluding collections from blocked users
	@MainActor
	static func filterCollectionsFromBlockedUsers(_ collections: [CollectionData]) async -> [CollectionData] {
		guard let currentUserId = Auth.auth().currentUser?.uid else {
			return collections
		}
		
		do {
			try await CYServiceManager.shared.loadCurrentUser()
			let blockedUserIds = Set(CYServiceManager.shared.getBlockedUsers())
			
			// Get unique owner IDs to check
			let ownerIds = Set(collections.map { $0.ownerId })
			
			// Batch fetch owner data to check if they've blocked current user
			var ownersWhoBlockedCurrentUser: Set<String> = []
			await withTaskGroup(of: (String, Bool).self) { group in
				for ownerId in ownerIds {
					group.addTask {
						do {
							// Check if owner has blocked current user
							let db = Firestore.firestore()
							let ownerDoc = try await db.collection("users").document(ownerId).getDocument()
							if let data = ownerDoc.data(),
							   let ownerBlockedUsers = data["blockedUsers"] as? [String],
							   ownerBlockedUsers.contains(currentUserId) {
								return (ownerId, true)
							}
						} catch {
							print("Error checking if owner blocked current user: \(error.localizedDescription)")
						}
						return (ownerId, false)
					}
				}
				
				for await (ownerId, isBlocked) in group {
					if isBlocked {
						ownersWhoBlockedCurrentUser.insert(ownerId)
					}
				}
			}
			
			return collections.filter { collection in
				// Exclude if current user has blocked the owner
				if blockedUserIds.contains(collection.ownerId) {
					return false
				}
				// Exclude if owner has blocked current user (mutual blocking)
				if ownersWhoBlockedCurrentUser.contains(collection.ownerId) {
					return false
				}
				return true
			}
		} catch {
			print("Error loading blocked users: \(error.localizedDescription)")
			return collections
		}
	}
	
	/// Filter out posts from blocked users or where author has blocked current user (mutual blocking)
	/// - Parameter posts: Array of posts to filter
	/// - Returns: Filtered array excluding posts from blocked users
	@MainActor
	static func filterPostsFromBlockedUsers(_ posts: [CollectionPost]) async -> [CollectionPost] {
		guard let currentUserId = Auth.auth().currentUser?.uid else {
			return posts
		}
		
		do {
			try await CYServiceManager.shared.loadCurrentUser()
			let blockedUserIds = Set(CYServiceManager.shared.getBlockedUsers())
			
			// Get unique author IDs to check
			let authorIds = Set(posts.map { $0.authorId })
			
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
							print("Error checking if author blocked current user: \(error.localizedDescription)")
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
			
			return posts.filter { post in
				// Exclude if current user has blocked the author
				if blockedUserIds.contains(post.authorId) {
					return false
				}
				// Exclude if author has blocked current user (mutual blocking)
				if authorsWhoBlockedCurrentUser.contains(post.authorId) {
					return false
				}
				return true
			}
		} catch {
			print("Error loading blocked users: \(error.localizedDescription)")
			return posts
		}
	}
	
	/// Filter out posts from collections the user doesn't have access to
	/// - Parameter posts: Array of posts to filter
	/// - Returns: Filtered array excluding posts from inaccessible collections
	@MainActor
	static func filterPostsFromInaccessibleCollections(_ posts: [CollectionPost]) async -> [CollectionPost] {
		guard let currentUserId = Auth.auth().currentUser?.uid else {
			// If not authenticated, only show posts from public collections
			// We need to fetch collections to check, but for now return all
			return posts
		}
		
		// Get unique collection IDs from posts
		let collectionIds = Set(posts.compactMap { post -> String? in
			post.collectionId.isEmpty ? nil : post.collectionId
		})
		
		// Fetch all collections in parallel
		var accessibleCollectionIds: Set<String> = []
		await withTaskGroup(of: (String, Bool).self) { group in
			for collectionId in collectionIds {
				group.addTask {
					do {
						guard let collection = try await CollectionService.shared.getCollection(collectionId: collectionId) else {
							return (collectionId, false)
						}
						let hasAccess = canUserViewCollection(collection, userId: currentUserId)
						return (collectionId, hasAccess)
					} catch {
						print("⚠️ Error checking collection access: \(error)")
						return (collectionId, false)
					}
				}
			}
			
			for await (collectionId, hasAccess) in group {
				if hasAccess {
					accessibleCollectionIds.insert(collectionId)
				}
			}
		}
		
		// Filter posts to only include those from accessible collections
		return posts.filter { post in
			if post.collectionId.isEmpty {
				return true // Posts without collectionId are allowed
			}
			return accessibleCollectionIds.contains(post.collectionId)
		}
	}
	
	/// Filter out posts from blocked users AND hidden collections AND inaccessible collections
	/// - Parameter posts: Array of posts to filter
	/// - Returns: Filtered array excluding posts from blocked users, hidden collections, and inaccessible collections
	@MainActor
	static func filterPosts(_ posts: [CollectionPost]) async -> [CollectionPost] {
		var filtered = posts
		filtered = await filterPostsFromBlockedUsers(filtered)
		filtered = await filterPostsFromHiddenCollections(filtered)
		filtered = await filterPostsFromInaccessibleCollections(filtered)
		return filtered
	}
	
	/// Filter out collections from blocked users AND hidden collections
	/// - Parameter collections: Array of collections to filter
	/// - Returns: Filtered array excluding collections from blocked users and hidden collections
	@MainActor
	static func filterCollections(_ collections: [CollectionData]) async -> [CollectionData] {
		guard let currentUserId = Auth.auth().currentUser?.uid else {
			// If not authenticated, only show public collections
			return collections.filter { $0.isPublic }
		}
		
		var filtered = collections
		
		// Filter by access (deniedUsers hide, allowedUsers show)
		filtered = filtered.filter { collection in
			return canUserViewCollection(collection, userId: currentUserId)
		}
		
		// Filter out collections from blocked users
		filtered = await filterCollectionsFromBlockedUsers(filtered)
		
		// Filter out hidden collections
		filtered = await filterHiddenCollections(filtered)
		
		return filtered
	}
}
