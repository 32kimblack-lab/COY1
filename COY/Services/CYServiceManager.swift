import SwiftUI
import Combine
import FirebaseFirestore
import FirebaseAuth

@MainActor
final class CYServiceManager: ObservableObject {
	static let shared = CYServiceManager()
	private init() {}

	struct CurrentUser {
		var profileImageURL: String
		var backgroundImageURL: String
		var name: String
		var username: String
		var blockedUsers: [String]
		var blockedCollectionIds: [String]
		var hiddenPostIds: [String]
		var starredPostIds: [String]
		var collectionSortPreference: String?
		var customCollectionOrder: [String]
		
		init(profileImageURL: String = "", backgroundImageURL: String = "", name: String = "", username: String = "", blockedUsers: [String] = [], blockedCollectionIds: [String] = [], hiddenPostIds: [String] = [], starredPostIds: [String] = [], collectionSortPreference: String? = nil, customCollectionOrder: [String] = []) {
			self.profileImageURL = profileImageURL
			self.backgroundImageURL = backgroundImageURL
			self.name = name
			self.username = username
			self.blockedUsers = blockedUsers
			self.blockedCollectionIds = blockedCollectionIds
			self.hiddenPostIds = hiddenPostIds
			self.starredPostIds = starredPostIds
			self.collectionSortPreference = collectionSortPreference
			self.customCollectionOrder = customCollectionOrder
		}
	}

	@Published var currentUser: CurrentUser?

	func loadCurrentUser() async throws {
		guard let userId = Auth.auth().currentUser?.uid else {
			throw NSError(domain: "CYServiceManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "No authenticated user"])
		}
		
		// Use backend API instead of direct Firestore
		let apiClient = APIClient.shared
		let userResponse = try await apiClient.getUser(userId: userId)
		
		self.currentUser = CurrentUser(
			profileImageURL: userResponse.profileImageURL ?? "",
			backgroundImageURL: userResponse.backgroundImageURL ?? "",
			name: userResponse.name,
			username: userResponse.username,
			blockedUsers: userResponse.blockedUsers ?? [],
			blockedCollectionIds: userResponse.blockedCollectionIds ?? [],
			hiddenPostIds: userResponse.hiddenPostIds ?? [],
			starredPostIds: userResponse.starredPostIds ?? [],
			collectionSortPreference: userResponse.collectionSortPreference,
			customCollectionOrder: userResponse.customCollectionOrder ?? []
		)
	}
	
	func getBlockedUsers() -> [String] {
		return currentUser?.blockedUsers ?? []
	}
	
	func unblockUser(userId: String) async throws {
		guard let currentUserId = Auth.auth().currentUser?.uid else {
			throw NSError(domain: "CYServiceManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "No authenticated user"])
		}
		
		let db = Firestore.firestore()
		let userRef = db.collection("users").document(currentUserId)
		
		// Remove from blockedUsers array
		try await userRef.updateData([
			"blockedUsers": FieldValue.arrayRemove([userId])
		])
		
		// Update local state
		if var user = currentUser {
			user.blockedUsers.removeAll { $0 == userId }
			self.currentUser = user
		}
		
		// Post notification
		NotificationCenter.default.post(name: Notification.Name("UserUnblocked"), object: userId)
	}
	
	func getStarredPostIds() -> [String] {
		return currentUser?.starredPostIds ?? []
	}
	
	func getCollectionSortPreference() -> String {
		return currentUser?.collectionSortPreference ?? "Newest to Oldest"
	}
	
	func getCustomCollectionOrder() -> [String] {
		return currentUser?.customCollectionOrder ?? []
	}
	
	func updateCollectionSortPreference(_ preference: String) async throws {
		guard let currentUserId = Auth.auth().currentUser?.uid else { return }
		
		// Use backend API instead of direct Firestore
		let apiClient = APIClient.shared
		let userResponse = try await apiClient.updateUser(
			userId: currentUserId,
			collectionSortPreference: preference,
			customCollectionOrder: nil
		)
		
		// Update local state
		if var user = currentUser {
			user.collectionSortPreference = preference
			self.currentUser = user
		}
	}
	
	func updateCustomCollectionOrder(_ order: [String]) async throws {
		guard let currentUserId = Auth.auth().currentUser?.uid else { return }
		
		// Use backend API instead of direct Firestore
		let apiClient = APIClient.shared
		let userResponse = try await apiClient.updateUser(
			userId: currentUserId,
			collectionSortPreference: nil,
			customCollectionOrder: order
		)
		
		// Update local state
		if var user = currentUser {
			user.customCollectionOrder = order
			self.currentUser = user
		}
	}
	
	func unhideCollection(collectionId: String) async throws {
		guard let currentUserId = Auth.auth().currentUser?.uid else { return }
		
		let db = Firestore.firestore()
		try await db.collection("users").document(currentUserId).updateData([
			"blockedCollectionIds": FieldValue.arrayRemove([collectionId])
		])
		
		if var user = currentUser {
			user.blockedCollectionIds.removeAll { $0 == collectionId }
			self.currentUser = user
		}
		
		NotificationCenter.default.post(name: Notification.Name("CollectionUnhidden"), object: collectionId)
	}
}

