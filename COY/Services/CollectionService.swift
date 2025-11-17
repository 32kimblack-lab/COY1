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
					let _ = try await imageRef.putData(imageData, metadata: nil)
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
			owners: [response.ownerId],
			imageURL: response.imageURL,
			invitedUsers: [],
			members: response.members,
			memberCount: response.memberCount,
			followers: [],
			followerCount: 0,
			allowedUsers: [],
			deniedUsers: [],
			createdAt: createdAt
		)
	}
	
	func getPostById(postId: String) async throws -> CollectionPost? {
		let db = Firestore.firestore()
		let doc = try await db.collection("posts").document(postId).getDocument()
		
		guard let data = doc.data() else { return nil }
		
		return CollectionPost(
			id: doc.documentID,
			title: data["title"] as? String ?? "",
			collectionId: data["collectionId"] as? String ?? "",
			authorId: data["authorId"] as? String ?? "",
			authorName: data["authorName"] as? String ?? "",
			createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? Date(),
			firstMediaItem: nil
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
					owners: [response.ownerId], // Backend may not return owners array, use ownerId
					imageURL: response.imageURL,
					invitedUsers: [], // Backend may not return this in list, will need to fetch individually
					members: response.members,
					memberCount: response.memberCount,
					followers: [], // Backend may not return this in list
					followerCount: 0, // Backend may not return this in list
					allowedUsers: [], // Backend may not return this in list
					deniedUsers: [], // Backend may not return this in list
					createdAt: createdAt
				)
			}
		} catch {
			// Fall back to Firebase if backend fails
			print("⚠️ Backend getUserCollections failed, falling back to Firebase: \(error.localizedDescription)")
			let db = Firestore.firestore()
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
		}
	}
	
	// Image upload is now handled by backend API
	// No need for direct Firebase Storage upload
}

