import SwiftUI
import Combine
import FirebaseFirestore
import FirebaseAuth

@MainActor
final class CYServiceManager: ObservableObject {
	static let shared = CYServiceManager()
	private init() {}

	struct CurrentUser: Equatable {
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
	private var userListener: ListenerRegistration?
	
	func loadCurrentUser() async throws {
		guard let userId = Auth.auth().currentUser?.uid else {
			throw NSError(domain: "CYServiceManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "No authenticated user"])
		}
		
		// Remove existing listener if any
		userListener?.remove()
		
		// Set up real-time listener for user document
		let db = Firestore.firestore()
		userListener = db.collection("users").document(userId).addSnapshotListener { [weak self] snapshot, error in
			Task { @MainActor in
				guard let self = self else { return }
				
				if let error = error {
					print("❌ CYServiceManager: Error listening to user updates: \(error.localizedDescription)")
					return
				}
				
				guard let snapshot = snapshot, let data = snapshot.data() else {
					// Create default user if not found
					self.currentUser = CurrentUser(
						profileImageURL: "",
						backgroundImageURL: "",
						name: "",
						username: "",
						blockedUsers: [],
						blockedCollectionIds: [],
						hiddenPostIds: [],
						starredPostIds: [],
						collectionSortPreference: nil,
						customCollectionOrder: []
					)
					return
				}
				
				// Check if profile-relevant fields changed before updating
				let newProfileImageURL = data["profileImageURL"] as? String ?? ""
				let newBackgroundImageURL = data["backgroundImageURL"] as? String ?? ""
				let newName = data["name"] as? String ?? ""
				let newUsername = data["username"] as? String ?? ""
				
				let profileChanged = self.currentUser?.profileImageURL != newProfileImageURL ||
					self.currentUser?.backgroundImageURL != newBackgroundImageURL ||
					self.currentUser?.name != newName ||
					self.currentUser?.username != newUsername
				
				// Update currentUser with real-time data
				self.currentUser = CurrentUser(
					profileImageURL: newProfileImageURL,
					backgroundImageURL: newBackgroundImageURL,
					name: newName,
					username: newUsername,
					blockedUsers: data["blockedUsers"] as? [String] ?? [],
					blockedCollectionIds: data["blockedCollectionIds"] as? [String] ?? [],
					hiddenPostIds: data["hiddenPostIds"] as? [String] ?? [],
					starredPostIds: data["starredPostIds"] as? [String] ?? [],
					collectionSortPreference: data["collectionSortPreference"] as? String,
					customCollectionOrder: data["customCollectionOrder"] as? [String] ?? []
				)
				
				// Only log if profile-relevant fields changed (reduce spam)
				if profileChanged {
					print("🔄 CYServiceManager: User profile data updated in real-time")
				}
			}
		}
	}
	
	func stopListening() {
		userListener?.remove()
		userListener = nil
	}
	
	/// Get list of users that the CURRENT USER has blocked
	/// This is for display purposes (e.g., block list in settings)
	/// NOTE: This does NOT include users who blocked the current user
	/// For visibility checks, use areUsersMutuallyBlocked() instead
	func getBlockedUsers() -> [String] {
		return currentUser?.blockedUsers ?? []
	}
	
	/// Check if the CURRENT USER has blocked a specific user
	/// This only checks one direction (current user -> other user)
	/// For visibility checks, use areUsersMutuallyBlocked() instead
	func isUserBlocked(userId: String) -> Bool {
		return currentUser?.blockedUsers.contains(userId) ?? false
	}
	
	/// Check if two users are mutually blocked (either direction blocks the other)
	/// Returns true if current user blocked the other user OR if the other user blocked current user
	/// 
	/// BLOCKING RULE: When User A blocks User B, both users lose visibility of each other.
	/// However, only User A's block list contains User B. User B's block list stays empty.
	/// This function checks BOTH directions to enforce mutual visibility loss.
	/// 
	/// Use this for:
	/// - Filtering posts, collections, comments, search results
	/// - Hiding profiles, preventing navigation
	/// - Any visibility/access checks
	/// 
	/// Do NOT use this for:
	/// - Displaying block lists (use getBlockedUsers() instead)
	func areUsersMutuallyBlocked(userId: String) async -> Bool {
		guard let currentUserId = Auth.auth().currentUser?.uid else {
			return false
		}
		
		// Check if current user blocked the other user
		let currentBlockedOther = isUserBlocked(userId: userId)
		if currentBlockedOther {
			return true
		}
		
		// Check if the other user blocked current user
		do {
			let db = Firestore.firestore()
			let otherUserDoc = try await db.collection("users").document(userId).getDocument()
			if let data = otherUserDoc.data(),
			   let otherUserBlockedUsers = data["blockedUsers"] as? [String],
			   otherUserBlockedUsers.contains(currentUserId) {
				return true
			}
		} catch {
			print("Error checking if user blocked current user: \(error.localizedDescription)")
		}
		
		return false
	}
	
	func blockUser(userId: String) async throws {
		guard let currentUserId = Auth.auth().currentUser?.uid else {
			throw NSError(domain: "CYServiceManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "No authenticated user"])
		}
		
		let db = Firestore.firestore()
		let userRef = db.collection("users").document(currentUserId)
		
		// Add to blockedUsers array
		try await userRef.updateData([
			"blockedUsers": FieldValue.arrayUnion([userId])
		])
		
		// Update local state
		if var user = currentUser {
			if !user.blockedUsers.contains(userId) {
				user.blockedUsers.append(userId)
			}
			self.currentUser = user
		}
		
		// Post notification with userInfo
		NotificationCenter.default.post(
			name: Notification.Name("UserBlocked"),
			object: userId,
			userInfo: ["blockedUserId": userId]
		)
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
		
		// Post notification with userInfo
		NotificationCenter.default.post(
			name: Notification.Name("UserUnblocked"),
			object: userId,
			userInfo: ["unblockedUserId": userId]
		)
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
		
		// Use Firebase directly
		let db = Firestore.firestore()
		try await db.collection("users").document(currentUserId).updateData([
			"collectionSortPreference": preference
		])
		
		// Update local state
		if var user = currentUser {
			user.collectionSortPreference = preference
			self.currentUser = user
		}
	}
	
	func updateCustomCollectionOrder(_ order: [String]) async throws {
		guard let currentUserId = Auth.auth().currentUser?.uid else { return }
		
		// Use Firebase directly
		let db = Firestore.firestore()
		try await db.collection("users").document(currentUserId).updateData([
			"customCollectionOrder": order
		])
		
		// Update local state
		if var user = currentUser {
			user.customCollectionOrder = order
			self.currentUser = user
		}
	}
	
	func hideCollection(collectionId: String) async throws {
		guard let currentUserId = Auth.auth().currentUser?.uid else {
			throw NSError(domain: "CYServiceManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "No authenticated user"])
		}
		
		let db = Firestore.firestore()
		try await db.collection("users").document(currentUserId).updateData([
			"blockedCollectionIds": FieldValue.arrayUnion([collectionId])
		])
		
		// Update local state
		if var user = currentUser {
			if !user.blockedCollectionIds.contains(collectionId) {
				user.blockedCollectionIds.append(collectionId)
			}
			self.currentUser = user
		}
		
		// Post notification to refresh UI
		NotificationCenter.default.post(name: Notification.Name("CollectionHidden"), object: collectionId)
		print("✅ Collection \(collectionId) hidden successfully")
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
	
	func isCollectionHidden(collectionId: String) -> Bool {
		return currentUser?.blockedCollectionIds.contains(collectionId) ?? false
	}
	
	func getHiddenCollectionIds() -> [String] {
		return currentUser?.blockedCollectionIds ?? []
	}
	
	func reportPost(postId: String, category: String, additionalDetails: String?) async throws {
		guard let currentUserId = Auth.auth().currentUser?.uid else {
			throw NSError(domain: "CYServiceManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "No authenticated user"])
		}
		
		let db = Firestore.firestore()
		
		// Save report to Firebase
		let reportRef = db.collection("reports").document()
		var reportData: [String: Any] = [
			"postId": postId,
			"reporterId": currentUserId,
			"category": category,
			"createdAt": Timestamp(),
			"status": "pending"
		]
		
		if let details = additionalDetails, !details.isEmpty {
			reportData["additionalDetails"] = details
		}
		
		try await reportRef.setData(reportData)
		
		// Hide the post by adding to hiddenPostIds
		let userRef = db.collection("users").document(currentUserId)
		try await userRef.updateData([
			"hiddenPostIds": FieldValue.arrayUnion([postId])
		])
		
		// Update local state
		if var user = currentUser {
			if !user.hiddenPostIds.contains(postId) {
				user.hiddenPostIds.append(postId)
			}
			self.currentUser = user
		}
		
		// Post notification
		NotificationCenter.default.post(name: Notification.Name("PostReported"), object: postId)
		NotificationCenter.default.post(name: Notification.Name("PostHidden"), object: postId)
	}
}

