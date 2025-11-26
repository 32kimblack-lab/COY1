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
			
		let docRef = try await db.collection("collections").addDocument(data: collectionData)
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
		// Use Firebase directly
		let db = Firestore.firestore()
		let doc = try await db.collection("collections").document(collectionId).getDocument()
		
		guard let data = doc.data() else { return nil }
		
		return CollectionData(
			id: doc.documentID,
			name: data["name"] as? String ?? "",
			description: data["description"] as? String ?? "",
			type: data["type"] as? String ?? "Individual",
			isPublic: data["isPublic"] as? Bool ?? false,
			ownerId: data["ownerId"] as? String ?? "",
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
		
		return CollectionPost(
			id: doc.documentID,
			title: data["title"] as? String ?? "",
			collectionId: data["collectionId"] as? String ?? "",
			authorId: data["authorId"] as? String ?? "",
			authorName: data["authorName"] as? String ?? "",
			createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? Date(),
			firstMediaItem: firstMediaItem,
			mediaItems: allMediaItems
		)
	}
	
	func getUserCollections(userId: String, forceFresh: Bool = false) async throws -> [CollectionData] {
		// Use Firebase directly
		let db = Firestore.firestore()
		
		// Query 1: Collections where user is the owner
		let ownedSnapshot = try await db.collection("collections")
			.whereField("ownerId", isEqualTo: userId)
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
		
		return Array(allCollections.values)
	}
	
	/// Get posts for a collection from Firebase (source of truth)
	func getCollectionPostsFromFirebase(collectionId: String) async throws -> [CollectionPost] {
		let db = Firestore.firestore()
		// Query without orderBy to avoid index requirement, then sort in memory
		let snapshot = try await db.collection("posts")
			.whereField("collectionId", isEqualTo: collectionId)
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
			
			return CollectionPost(
				id: doc.documentID,
				title: data["title"] as? String ?? data["caption"] as? String ?? "",
				collectionId: data["collectionId"] as? String ?? "",
				authorId: data["authorId"] as? String ?? "",
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
		print("🗑️ CollectionService: Starting permanent delete for collection: \(collectionId)")
		
		// Use Firebase directly
		let db = Firestore.firestore()
		let storage = Storage.storage()
		
		// Step 1: Get all posts in the collection
		let postsSnapshot = try await db.collection("posts")
			.whereField("collectionId", isEqualTo: collectionId)
			.getDocuments()
		
		print("📋 Found \(postsSnapshot.documents.count) posts to delete")
		
		// Step 2: For each post, delete comments and media files
		for postDoc in postsSnapshot.documents {
			let postId = postDoc.documentID
			let postData = postDoc.data()
			
			// Delete all comments for this post
			let commentsSnapshot = try await db.collection("posts")
				.document(postId)
				.collection("comments")
				.getDocuments()
			
			print("🗑️ Deleting \(commentsSnapshot.documents.count) comments for post \(postId)")
			for commentDoc in commentsSnapshot.documents {
				try await commentDoc.reference.delete()
			}
			
			// Delete media files from Firebase Storage
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
			try await postDoc.reference.delete()
			print("✅ Deleted post \(postId)")
		}
		
		print("✅ Deleted \(postsSnapshot.documents.count) posts and all their comments/media from collection")
		
		// Step 3: Delete collection image from Storage if exists
		// Get collection data first to find image URL
		let deletedRef = db.collection("users").document(ownerId).collection("deleted_collections").document(collectionId)
		if let deletedData = try? await deletedRef.getDocument().data(),
		   let imageURL = deletedData["imageURL"] as? String, !imageURL.isEmpty {
			if let url = URL(string: imageURL) {
				let imageRef = storage.reference(forURL: url.absoluteString)
				try? await imageRef.delete()
				print("🗑️ Deleted collection image: \(imageURL)")
			}
		}
		
		// Step 4: Delete from deleted_collections subcollection
		try await deletedRef.delete()
		print("✅ Deleted collection from deleted_collections subcollection")
		
		// Step 5: Also delete from main collections if it somehow still exists
		let mainCollectionRef = db.collection("collections").document(collectionId)
		if (try? await mainCollectionRef.getDocument().exists) == true {
			try await mainCollectionRef.delete()
			print("✅ Deleted collection from main collections")
		}
		
		print("✅ CollectionService: Collection permanently deleted with ALL related data")
		
		// Post notification so collection disappears from deleted collections view
		Task { @MainActor in
			NotificationCenter.default.post(
				name: NSNotification.Name("CollectionDeleted"),
				object: collectionId,
				userInfo: ["permanent": true]
			)
			print("📢 CollectionService: Posted CollectionDeleted notification (permanent)")
		}
		
		print("✅ CollectionService: Permanent delete completed successfully for collection: \(collectionId)")
	}
	
	func getDeletedCollections(ownerId: String) async throws -> [(CollectionData, Date)] {
		let db = Firestore.firestore()
		let snapshot = try await db.collection("users").document(ownerId).collection("deleted_collections").getDocuments()
		
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
			
			let collection = CollectionData(
				id: doc.documentID,
				name: data["name"] as? String ?? "",
				description: data["description"] as? String ?? "",
				type: data["type"] as? String ?? "Individual",
				isPublic: data["isPublic"] as? Bool ?? false,
				ownerId: data["ownerId"] as? String ?? ownerId,
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
		
		// Get collection to check if user is owner (cannot remove owner)
		guard let collection = try await getCollection(collectionId: collectionId) else {
			throw NSError(domain: "CollectionService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Collection not found"])
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
		
		// Get current memberJoinDates
		let collectionDoc = try await collectionRef.getDocument()
		var memberJoinDates = collectionDoc.data()?["memberJoinDates"] as? [String: Timestamp] ?? [:]
		memberJoinDates[requesterId] = Timestamp()
		
		// Add requester to members
		try await collectionRef.updateData([
			"members": FieldValue.arrayUnion([requesterId]),
			"memberCount": FieldValue.increment(Int64(1)),
			"memberJoinDates": memberJoinDates
		])
		
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
		
		// Use Firebase directly
		let db = Firestore.firestore()
		let collectionRef = db.collection("collections").document(collectionId)
		
		// Get current memberJoinDates
		let collectionDoc = try await collectionRef.getDocument()
		var memberJoinDates = collectionDoc.data()?["memberJoinDates"] as? [String: Timestamp] ?? [:]
		memberJoinDates[currentUserId] = Timestamp()
		
		// Add user to members
		try await collectionRef.updateData([
			"members": FieldValue.arrayUnion([currentUserId]),
			"memberCount": FieldValue.increment(Int64(1)),
			"memberJoinDates": memberJoinDates
		])
		
		// Remove from invitedUsers if present
		try await collectionRef.updateData([
			"invitedUsers": FieldValue.arrayRemove([currentUserId])
		])
		
		// Also add collection to user's user document (for profile display)
		let userRef = db.collection("users").document(currentUserId)
		try await userRef.updateData([
			"collections": FieldValue.arrayUnion([collectionId])
		])
		
		print("✅ CollectionService: User \(currentUserId) accepted invite and joined collection \(collectionId)")
		
		// Delete the notification
		try await NotificationService.shared.deleteNotification(
			notificationId: notificationId,
			userId: currentUserId
		)
		
		// Post notification to update UI (use Task to avoid priority inversion)
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
			// Post notification to refresh user's profile collections
			NotificationCenter.default.post(
				name: NSNotification.Name("UserCollectionsUpdated"),
				object: currentUserId
			)
		}
		
		print("✅ CollectionService: Collection invite accepted for user \(currentUserId)")
	}
	
	func denyCollectionInvite(collectionId: String, notificationId: String) async throws {
		guard let currentUserId = Auth.auth().currentUser?.uid else {
			throw NSError(domain: "CollectionService", code: -1, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])
		}
		
		// Verify collection exists
		guard try await getCollection(collectionId: collectionId) != nil else {
			throw NSError(domain: "CollectionService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Collection not found"])
		}
		
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
		
		// Post notification to update UI
		Task { @MainActor in
			NotificationCenter.default.post(
				name: NSNotification.Name("CollectionInviteDenied"),
				object: collectionId,
				userInfo: ["userId": currentUserId]
			)
		}
		
		print("✅ CollectionService: Collection invite denied for user \(currentUserId)")
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
		
		// Use Firebase directly with transaction for atomic operation
		let db = Firestore.firestore()
		let collectionRef = db.collection("collections").document(collectionId)
		
		// Use transaction to atomically add member and handle batch notifications
		var shouldSendNotification = false
		var pendingJoinsToNotify: [[String: Any]] = []
		var collectionNameForNotification = ""
		
		_ = try await db.runTransaction { transaction, errorPointer -> Any? in
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
				
				// Determine threshold (random between 5-10 for batch notifications)
				let threshold = Int.random(in: 5...10)
				
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
		
		// Send notification outside transaction if threshold reached
		if shouldSendNotification {
			try await NotificationService.shared.sendBatchJoinNotification(
				collectionId: collectionId,
				collectionName: collectionNameForNotification,
				joinedUsers: pendingJoinsToNotify
			)
		}
		
		print("✅ CollectionService: User \(currentUserId) joined collection \(collectionId)")
		
		// Post notification to update UI
		Task { @MainActor in
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
			// Post notification to refresh user's profile collections
			NotificationCenter.default.post(
				name: NSNotification.Name("UserCollectionsUpdated"),
				object: currentUserId
			)
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
		
		// Delete the post document
		try await postRef.delete()
		
		// Post notification
		Task { @MainActor in
			NotificationCenter.default.post(
				name: NSNotification.Name("PostDeleted"),
				object: postId
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
		
		// Update allowDownload
		if let allowDownload = allowDownload {
			updateData["allowDownload"] = allowDownload
		}
		
		// Update allowReplies
		if let allowReplies = allowReplies {
			updateData["allowReplies"] = allowReplies
		}
		
		// Only update if there are changes
		guard !updateData.isEmpty else {
			print("⚠️ No changes to update for post \(postId)")
			return
		}
		
		// Update the post document
		try await postRef.updateData(updateData)
		
		print("✅ Post \(postId) updated successfully")
		
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
		
		// NEW ACCESS SYSTEM:
		// If user is in deniedUsers → hide collection (return false)
		if collection.deniedUsers.contains(userId) {
			return false
		}
		
		// If user is in allowedUsers → show collection everywhere (return true, even if private)
		if collection.allowedUsers.contains(userId) {
			return true
		}
		
		// Default behavior: public collections are visible, private collections are not
		return collection.isPublic
	}
	
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
		
		return followedCollections
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

