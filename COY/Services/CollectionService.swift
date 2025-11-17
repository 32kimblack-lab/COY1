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
		// Use backend API instead of direct Firestore
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
		// Use backend API instead of direct Firestore
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
	}
	
	// Image upload is now handled by backend API
	// No need for direct Firebase Storage upload
}

