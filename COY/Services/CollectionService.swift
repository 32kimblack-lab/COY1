import Foundation
import FirebaseFirestore
import FirebaseStorage
import UIKit

@MainActor
final class CollectionService {
	static let shared = CollectionService()
	private init() {}
	
	private let apiClient = APIClient.shared
	
	func createCollection(name: String, description: String, type: String, isPublic: Bool, ownerId: String, ownerName: String, image: UIImage?, invitedUsers: [String]) async throws -> String {
		// Try backend API first, fall back to Firebase if it fails
		do {
			let response = try await apiClient.createCollection(
				name: name,
				description: description,
				type: type,
				isPublic: isPublic,
				ownerId: ownerId,
				ownerName: ownerName,
				image: image,
				invitedUsers: invitedUsers
			)
			return response.id
		} catch {
			// Fall back to Firebase if backend fails
			print("⚠️ Backend createCollection failed, falling back to Firebase: \(error.localizedDescription)")
			let db = Firestore.firestore()
			var collectionData: [String: Any] = [
				"name": name,
				"description": description,
				"type": type,
				"isPublic": isPublic,
				"ownerId": ownerId,
				"ownerName": ownerName,
				"members": [ownerId] + invitedUsers,
				"memberCount": 1 + invitedUsers.count,
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
			return docRef.documentID
		}
	}
	
	func getCollection(collectionId: String) async throws -> CollectionData? {
		// Use backend API instead of direct Firestore
		let response = try await apiClient.getCollection(collectionId: collectionId)
		
		// Parse createdAt from string
		let dateFormatter = ISO8601DateFormatter()
		dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		let createdAt = dateFormatter.date(from: response.createdAt) ?? Date()
		
				return CollectionData(
					id: response.id,
					name: response.name,
					description: response.description,
					type: response.type,
					isPublic: response.isPublic,
					ownerId: response.ownerId,
					ownerName: response.ownerName,
					owners: response.owners ?? [response.ownerId],
					admins: response.admins,
					imageURL: response.imageURL,
					invitedUsers: [],
					members: response.members,
					memberCount: response.memberCount,
					followers: [],
					followerCount: 0,
					allowedUsers: response.allowedUsers ?? [],
					deniedUsers: response.deniedUsers ?? [],
					createdAt: createdAt
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
					isVideo: mediaData["isVideo"] as? Bool ?? false,
					width: (mediaData["width"] as? Double).map { CGFloat($0) },
					height: (mediaData["height"] as? Double).map { CGFloat($0) }
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
		// Try backend API first, fall back to Firebase if it fails
		do {
			let responses = try await apiClient.getUserCollections(userId: userId)
			
			// Convert CollectionResponse to CollectionData
			return responses.map { response in
				// Parse createdAt from string
				let dateFormatter = ISO8601DateFormatter()
				dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
				let createdAt = dateFormatter.date(from: response.createdAt) ?? Date()
				
				return CollectionData(
					id: response.id,
					name: response.name,
					description: response.description,
					type: response.type,
					isPublic: response.isPublic,
					ownerId: response.ownerId,
					ownerName: response.ownerName,
					owners: response.owners ?? [response.ownerId], // Use owners array if provided, otherwise use ownerId
					admins: response.admins, // Admins promoted by Owner
					imageURL: response.imageURL,
					invitedUsers: [], // Backend may not return this in list, will need to fetch individually
					members: response.members,
					memberCount: response.memberCount,
					followers: [], // Backend may not return this in list
					followerCount: 0, // Backend may not return this in list
					allowedUsers: response.allowedUsers ?? [], // Use allowedUsers from response
					deniedUsers: response.deniedUsers ?? [], // Use deniedUsers from response
					createdAt: createdAt
				)
			}
		} catch {
			// Fall back to Firebase if backend fails
			print("⚠️ Backend getUserCollections failed, falling back to Firebase: \(error.localizedDescription)")
			let db = Firestore.firestore()
			do {
				let snapshot = try await db.collection("collections")
					.whereField("ownerId", isEqualTo: userId)
					.getDocuments()
				
				return snapshot.documents.compactMap { doc in
					let data = doc.data()
					return CollectionData(
						id: doc.documentID,
						name: data["name"] as? String ?? "",
						description: data["description"] as? String ?? "",
						type: data["type"] as? String ?? "Individual",
						isPublic: data["isPublic"] as? Bool ?? false,
						ownerId: data["ownerId"] as? String ?? userId,
						ownerName: data["ownerName"] as? String ?? "",
						owners: data["owners"] as? [String] ?? [userId],
						admins: data["admins"] as? [String],
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
				}
			} catch {
				// If Firebase also fails, return empty array
				print("❌ Firebase getUserCollections also failed: \(error.localizedDescription)")
				return []
			}
		}
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
						isVideo: mediaData["isVideo"] as? Bool ?? false,
						width: (mediaData["width"] as? Double).map { CGFloat($0) },
						height: (mediaData["height"] as? Double).map { CGFloat($0) }
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
					isVideo: firstMediaData["isVideo"] as? Bool ?? false,
					width: (firstMediaData["width"] as? Double).map { CGFloat($0) },
					height: (firstMediaData["height"] as? Double).map { CGFloat($0) }
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
				mediaItems: allMediaItems
			)
		}
		// Sort by createdAt descending (newest first)
		return loadedPosts.sorted { $0.createdAt > $1.createdAt }
	}
	
	// MARK: - Soft Delete System
	func softDeleteCollection(collectionId: String) async throws {
		print("🗑️ CollectionService: Starting soft delete for collection: \(collectionId)")
		
		// CRITICAL FIX: Use backend API first (source of truth)
		// Backend handles soft delete in Firebase and MongoDB
		do {
			try await apiClient.deleteCollection(collectionId: collectionId)
			print("✅ CollectionService: Collection deleted via backend API")
		} catch {
			print("⚠️ CollectionService: Backend API failed, falling back to Firestore: \(error)")
			
			// Fallback to Firestore if backend fails
			// Get ownerId from backend API first
			var ownerId: String
			do {
				if let collection = try await getCollection(collectionId: collectionId) {
					ownerId = collection.ownerId
					print("✅ CollectionService: Found collection owner from backend: \(ownerId)")
				} else {
					throw NSError(domain: "CollectionService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Collection not found"])
				}
			} catch {
				throw NSError(domain: "CollectionService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Collection not found"])
			}
			
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
		}
		
		// Post notification so collection disappears immediately from UI
		await MainActor.run {
			NotificationCenter.default.post(
				name: NSNotification.Name("CollectionDeleted"),
				object: collectionId,
				userInfo: ["ownerId": ""] // Backend will handle ownerId
			)
			print("📢 CollectionService: Posted CollectionDeleted notification")
		}
		
		print("✅ CollectionService: Soft delete completed successfully for collection: \(collectionId)")
	}
	
	func recoverCollection(collectionId: String, ownerId: String) async throws {
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
		
		// Post notification so collection appears immediately in UI
		await MainActor.run {
			NotificationCenter.default.post(
				name: NSNotification.Name("CollectionRestored"),
				object: collectionId,
				userInfo: ["ownerId": ownerId]
			)
		}
	}
	
	func permanentlyDeleteCollection(collectionId: String, ownerId: String) async throws {
		let db = Firestore.firestore()
		let deletedRef = db.collection("users").document(ownerId).collection("deleted_collections").document(collectionId)
		
		// Permanently delete
		try await deletedRef.delete()
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
				admins: data["admins"] as? [String],
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
	
	// Image upload is now handled by backend API
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
				let storageService = await MainActor.run { StorageService.shared }
				finalImageURL = try await storageService.uploadCollectionImage(image, collectionId: collectionId)
				print("✅ Collection image uploaded to Firebase Storage: \(finalImageURL ?? "nil")")
			} catch {
				print("❌ CollectionService: Failed to upload collection image to Firebase Storage: \(error)")
				throw error
			}
		}
		
		// CRITICAL FIX: Save to Firebase FIRST (source of truth) - MATCHES EDIT PROFILE PATTERN
		// This ensures Firebase listeners see changes immediately
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
		
		// Save to Firebase FIRST (source of truth) - like edit profile
		if !firestoreUpdate.isEmpty {
			try await collectionRef.updateData(firestoreUpdate)
			print("✅ CollectionService: Collection updated in Firebase Firestore (source of truth)")
		}
		
		// Sync to backend API (like edit profile syncs after Firebase)
		do {
			let _ = try await apiClient.updateCollection(
				collectionId: collectionId,
				name: name,
				description: description,
				image: nil, // Don't send image data - we use Firebase Storage URLs
				imageURL: finalImageURL, // Send Firebase Storage URL to backend
				isPublic: isPublic,
				allowedUsers: allowedUsers,  // Send array even if empty
				deniedUsers: deniedUsers  // Send array even if empty
			)
			print("✅ CollectionService: Collection synced to backend API")
		} catch {
			// Log error but don't fail - Firebase is source of truth (like edit profile)
			print("⚠️ Failed to sync to backend (Firebase is source of truth): \(error.localizedDescription)")
		}
		
		// Clear collection cache to force fresh load (like edit profile clears cache)
		// Note: CollectionService doesn't have a cache like UserService, but we can clear ImageCache
		if let oldImageURL = imageURL, !oldImageURL.isEmpty {
			ImageCache.shared.removeImage(for: oldImageURL)
		}
		
		// Post comprehensive notification for immediate UI updates (like edit profile)
		await MainActor.run {
			var updateData: [String: Any] = [
				"collectionId": collectionId
			]
			
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
			
			print("📢 CollectionService: Posted CollectionUpdated notification with all changes")
		}
	}
	
	func promoteToAdmin(collectionId: String, userId: String) async throws {
		print("👤 CollectionService: Promoting user \(userId) to admin in collection \(collectionId)")
		
		// CRITICAL FIX: Use backend API first, then update Firestore
		do {
			try await apiClient.promoteMemberToAdmin(collectionId: collectionId, memberId: userId)
			print("✅ CollectionService: User promoted via backend API")
		} catch {
			print("⚠️ CollectionService: Backend API failed, falling back to Firestore: \(error)")
			// Fallback to Firestore if backend fails
		let db = Firestore.firestore()
		let collectionRef = db.collection("collections").document(collectionId)
		
		// Add to admins array
		try await collectionRef.updateData([
			"admins": FieldValue.arrayUnion([userId])
		])
			print("✅ CollectionService: User promoted via Firestore fallback")
		}
		
		// Post notification to refresh UI
		await MainActor.run {
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
		
		// CRITICAL FIX: Use backend API first, then update Firestore
		do {
			try await apiClient.removeMemberFromCollection(collectionId: collectionId, memberId: userId)
			print("✅ CollectionService: Member removed via backend API")
		} catch {
			print("⚠️ CollectionService: Backend API failed, falling back to Firestore: \(error)")
			// Fallback to Firestore if backend fails
			let db = Firestore.firestore()
			let collectionRef = db.collection("collections").document(collectionId)
			
			// Remove from members array
			try await collectionRef.updateData([
				"members": FieldValue.arrayRemove([userId]),
				"memberCount": FieldValue.increment(Int64(-1))
			])
			
			// Also remove from admins if they were an admin
			try await collectionRef.updateData([
				"admins": FieldValue.arrayRemove([userId])
			])
			print("✅ CollectionService: Member removed via Firestore fallback")
		}
		
		// Post notification to refresh UI
		await MainActor.run {
			NotificationCenter.default.post(
				name: NSNotification.Name("CollectionUpdated"),
				object: collectionId,
				userInfo: ["action": "memberRemoved", "userId": userId]
			)
		}
		
		print("✅ CollectionService: User \(userId) removed from collection \(collectionId)")
	}
	
	func leaveCollection(collectionId: String, userId: String) async throws {
		print("👋 CollectionService: User \(userId) leaving collection \(collectionId)")
		
		// CRITICAL FIX: Use backend API first (source of truth)
		// Backend handles leaving in Firebase and MongoDB
		do {
			try await apiClient.leaveCollection(collectionId: collectionId)
			print("✅ CollectionService: User left via backend API")
		} catch {
			print("⚠️ CollectionService: Backend API failed, falling back to Firestore: \(error)")
			
			// Fallback to Firestore if backend fails
			let db = Firestore.firestore()
			let collectionRef = db.collection("collections").document(collectionId)
			
			// Remove from members array
			try await collectionRef.updateData([
				"members": FieldValue.arrayRemove([userId]),
				"memberCount": FieldValue.increment(Int64(-1))
			])
			
			// Also remove from admins if they were an admin
			try await collectionRef.updateData([
				"admins": FieldValue.arrayRemove([userId])
			])
			
			print("✅ CollectionService: User left via Firestore fallback")
		}
		
		// Post notification for real-time UI updates
		await MainActor.run {
			NotificationCenter.default.post(
				name: NSNotification.Name("CollectionUpdated"),
				object: collectionId,
				userInfo: ["action": "memberLeft", "userId": userId]
			)
			print("📢 CollectionService: Posted CollectionUpdated notification for member leaving")
		}
		
		print("✅ CollectionService: User \(userId) left collection \(collectionId)")
	}
	
	// MARK: - Post Management
	func deletePost(postId: String) async throws {
		// Delete via backend API
		try await apiClient.deletePost(postId: postId)
	}
	
	func togglePostPin(postId: String, isPinned: Bool) async throws {
		_ = try await apiClient.togglePostPin(postId: postId, isPinned: isPinned)
	}
	
	// MARK: - Privacy Helper Functions
	
	/// Check if a user can view a collection based on privacy settings
	/// - Parameters:
	///   - collection: The collection to check
	///   - userId: The user ID to check access for
	/// - Returns: true if the user can view the collection, false otherwise
	static func canUserViewCollection(_ collection: CollectionData, userId: String) -> Bool {
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
		
		// For private collections: user must be in allowedUsers
		if !collection.isPublic {
			return collection.allowedUsers.contains(userId)
		}
		
		// For public collections: user must NOT be in deniedUsers
		if collection.isPublic {
			return !collection.deniedUsers.contains(userId)
		}
		
		// Default: deny access
		return false
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
		return allCollections.filter { collection in
			return CollectionService.canUserViewCollection(collection, userId: viewingUserId)
		}
	}
}

