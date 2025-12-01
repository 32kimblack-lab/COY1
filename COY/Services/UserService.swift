import SwiftUI
import Combine
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage

@MainActor
final class UserService: ObservableObject {
	static let shared = UserService()
	private init() {}
	
	// Helper function to add timeout to async operations
	private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
		return try await withThrowingTaskGroup(of: T.self) { group in
			// Add the actual operation
			group.addTask {
				try await operation()
			}
			
			// Add timeout task
			group.addTask {
				try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
				throw TimeoutError()
			}
			
			// Get the first completed task
			guard let result = try await group.next() else {
				throw TimeoutError()
			}
			
			// Cancel remaining tasks
			group.cancelAll()
			return result
		}
	}
	
	private struct TimeoutError: Error {
		let localizedDescription = "Request timed out. Please check your internet connection."
	}

	struct AppUser: Identifiable, Equatable {
		var id: String { userId }
		var userId: String
		var name: String
		var username: String
		var profileImageURL: String?
		var backgroundImageURL: String?
		var birthMonth: String
		var birthDay: String
		var birthYear: String
		var email: String
		
		init(userId: String, name: String = "", username: String = "", profileImageURL: String? = nil, backgroundImageURL: String? = nil, birthMonth: String = "", birthDay: String = "", birthYear: String = "", email: String = "") {
			self.userId = userId
			self.name = name
			self.username = username
			self.profileImageURL = profileImageURL
			self.backgroundImageURL = backgroundImageURL
			self.birthMonth = birthMonth
			self.birthDay = birthDay
			self.birthYear = birthYear
			self.email = email
		}
	}

	private var cache: [String: AppUser] = [:]
	// Real-time listeners for user profiles - automatically updates when users edit their profile
	private var userListeners: [String: ListenerRegistration] = [:]

	func clearUserCache(userId: String) {
		cache[userId] = nil
		// Remove listener when cache is cleared
		userListeners[userId]?.remove()
		userListeners[userId] = nil
	}
	
	/// Subscribe to real-time updates for a user's profile
	/// This ensures profile images, usernames, and names update everywhere when edited
	func subscribeToUserProfile(userId: String) {
		// Don't create duplicate listeners
		guard userListeners[userId] == nil else { return }
		
		let db = Firestore.firestore()
		userListeners[userId] = db.collection("users").document(userId).addSnapshotListener { [weak self] snapshot, error in
			Task { @MainActor in
				guard let self = self else { return }
				
				if let error = error {
					print("❌ UserService: Error listening to user \(userId) updates: \(error.localizedDescription)")
					return
				}
				
				guard let snapshot = snapshot, let data = snapshot.data() else {
					return
				}
				
				// Check if profile-relevant fields changed
				let newName = data["name"] as? String ?? ""
				let newUsername = data["username"] as? String ?? ""
				let newProfileImageURL = data["profileImageURL"] as? String
				let newBackgroundImageURL = data["backgroundImageURL"] as? String
				
				// Get old cached user to compare
				let oldUser = self.cache[userId]
				let profileChanged = oldUser?.name != newName ||
					oldUser?.username != newUsername ||
					oldUser?.profileImageURL != newProfileImageURL ||
					oldUser?.backgroundImageURL != newBackgroundImageURL
				
				// Update cache with new data
				let updatedUser = AppUser(
					userId: userId,
					name: newName,
					username: newUsername,
					profileImageURL: newProfileImageURL,
					backgroundImageURL: newBackgroundImageURL,
					birthMonth: data["birthMonth"] as? String ?? "",
					birthDay: data["birthDay"] as? String ?? "",
					birthYear: data["birthYear"] as? String ?? "",
					email: data["email"] as? String ?? ""
				)
				self.cache[userId] = updatedUser
				
				// Post notification if profile changed (so all views update)
				if profileChanged {
					print("🔄 UserService: User \(userId) profile updated in real-time - name: '\(newName)', username: '\(newUsername)'")
					NotificationCenter.default.post(
						name: Notification.Name("UserProfileUpdated"),
						object: userId,
						userInfo: [
							"userId": userId,
							"name": newName,
							"username": newUsername,
							"profileImageURL": newProfileImageURL as Any,
							"backgroundImageURL": newBackgroundImageURL as Any
						]
					)
				}
			}
		}
	}
	
	/// Unsubscribe from real-time updates for a user (cleanup)
	func unsubscribeFromUserProfile(userId: String) {
		userListeners[userId]?.remove()
		userListeners[userId] = nil
	}
	
	/// Cleanup all listeners (call on logout or app termination)
	func cleanupAllListeners() {
		for (_, listener) in userListeners {
			listener.remove()
		}
		userListeners.removeAll()
		cache.removeAll()
	}

	func isUsernameAvailable(_ username: String) async throws -> Bool {
		let db = Firestore.firestore()
		// Usernames are stored in lowercase, so check lowercase
		let lowercaseUsername = username.lowercased()
		
		let snapshot = try await db.collection("users")
			.whereField("username", isEqualTo: lowercaseUsername)
			.limit(to: 1)
			.getDocuments()
		
		return snapshot.documents.isEmpty
	}
	
	func getUserByUsername(_ username: String) async throws -> AppUser? {
		let db = Firestore.firestore()
		// Usernames are stored in lowercase, so search lowercase
		// Also trim whitespace to handle any input issues
		let normalizedUsername = username.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
		
		print("🔍 Searching for username: '\(normalizedUsername)'")
		
		// Add timeout to prevent hanging on slow/no network
		do {
			// First try exact match with lowercase (for new users)
			let snapshot = try await withTimeout(seconds: 8) {
				try await db.collection("users")
					.whereField("username", isEqualTo: normalizedUsername)
					.limit(to: 1)
					.getDocuments()
			}
		
			// If not found, try case-insensitive search by getting all users and filtering
			// (This handles legacy users who might have mixed-case usernames)
			// CRITICAL FIX: Reduce limit for better performance
			if snapshot.documents.isEmpty {
				print("⚠️ Username not found with exact match, trying case-insensitive search...")
				// Get a smaller batch and filter client-side (less efficient but handles edge cases)
				// NOTE: This is a fallback - ideally all usernames should be stored lowercase
				let allUsersSnapshot = try await withTimeout(seconds: 8) {
					try await db.collection("users")
						.limit(to: 100) // Reduced from 1000 to 100 for better performance
						.getDocuments()
				}
			
			// Filter for case-insensitive match
			for doc in allUsersSnapshot.documents {
				let data = doc.data()
				if let storedUsername = data["username"] as? String,
				   storedUsername.lowercased() == normalizedUsername {
					let foundUserId = doc.documentID
					print("✅ Found user with case-insensitive match")
					
					// Check if user is blocked (mutual blocking)
					if await CYServiceManager.shared.areUsersMutuallyBlocked(userId: foundUserId) {
						print("🚫 User \(foundUserId) is blocked, returning nil")
						return nil
					}
					
					return AppUser(
						userId: foundUserId,
						name: data["name"] as? String ?? "",
						username: storedUsername,
						profileImageURL: data["profileImageURL"] as? String,
						backgroundImageURL: data["backgroundImageURL"] as? String,
						birthMonth: data["birthMonth"] as? String ?? "",
						birthDay: data["birthDay"] as? String ?? "",
						birthYear: data["birthYear"] as? String ?? "",
						email: data["email"] as? String ?? ""
					)
				}
			}
			
				print("❌ Username not found even with case-insensitive search")
				return nil
			}
			
			guard let doc = snapshot.documents.first else {
				print("❌ No documents found")
				return nil
			}
			
			let data = doc.data()
			let foundUserId = doc.documentID
			print("✅ Found user: \(foundUserId), email: \(data["email"] as? String ?? "none")")
			
			// Check if user is blocked (mutual blocking)
			if await CYServiceManager.shared.areUsersMutuallyBlocked(userId: foundUserId) {
				print("🚫 User \(foundUserId) is blocked, returning nil")
				return nil
			}
			
			return AppUser(
				userId: foundUserId,
				name: data["name"] as? String ?? "",
				username: data["username"] as? String ?? "",
				profileImageURL: data["profileImageURL"] as? String,
				backgroundImageURL: data["backgroundImageURL"] as? String,
				birthMonth: data["birthMonth"] as? String ?? "",
				birthDay: data["birthDay"] as? String ?? "",
				birthYear: data["birthYear"] as? String ?? "",
				email: data["email"] as? String ?? ""
			)
		} catch is TimeoutError {
			print("⏱️ Username lookup timed out - network may be slow or unavailable")
			throw NSError(domain: "FIRFirestoreErrorDomain", code: 14, userInfo: [NSLocalizedDescriptionKey: "Request timed out. Please check your internet connection."])
		} catch {
			// Re-throw other errors
			throw error
		}
	}

	func getUser(userId: String) async throws -> AppUser? {
		// Check if user is blocked (mutual blocking) before returning cached or fetching
		if await CYServiceManager.shared.areUsersMutuallyBlocked(userId: userId) {
			print("🚫 User \(userId) is blocked, returning nil")
			// Remove from cache if blocked
			cache[userId] = nil
			return nil
		}
		
		if let cached = cache[userId] { return cached }
		
		// Firebase is source of truth - load from Firebase first
		let db = Firestore.firestore()
		let doc = try await db.collection("users").document(userId).getDocument()
		
		guard let data = doc.data() else { return nil }
		
		// Double-check blocking after fetching (in case blocking happened between check and fetch)
		if await CYServiceManager.shared.areUsersMutuallyBlocked(userId: userId) {
			print("🚫 User \(userId) is blocked after fetch, returning nil")
			return nil
		}
		
		let user = AppUser(
			userId: userId,
			name: data["name"] as? String ?? "",
			username: data["username"] as? String ?? "",
			profileImageURL: data["profileImageURL"] as? String,
			backgroundImageURL: data["backgroundImageURL"] as? String,
			birthMonth: data["birthMonth"] as? String ?? "",
			birthDay: data["birthDay"] as? String ?? "",
			birthYear: data["birthYear"] as? String ?? "",
			email: data["email"] as? String ?? ""
		)
		
		cache[userId] = user
		
		// Automatically subscribe to real-time updates for this user
		// This ensures profile changes update everywhere in the app
		subscribeToUserProfile(userId: userId)
		
		return user
	}
	
	func getAllUsers() async throws -> [User] {
		let db = Firestore.firestore()
		// CRITICAL FIX: Add limit to prevent loading all users (could be millions)
		// This should only be used for admin/search purposes with proper limits
		let snapshot = try await db.collection("users")
			.limit(to: 1000) // Maximum 1000 users (should use search/pagination instead)
			.getDocuments()
		
		let users = snapshot.documents.compactMap { doc -> AppUser? in
			let data = doc.data()
			return AppUser(
				userId: doc.documentID,
				name: data["name"] as? String ?? "",
				username: data["username"] as? String ?? "",
				profileImageURL: data["profileImageURL"] as? String,
				backgroundImageURL: data["backgroundImageURL"] as? String,
				birthMonth: data["birthMonth"] as? String ?? "",
				birthDay: data["birthDay"] as? String ?? "",
				birthYear: data["birthYear"] as? String ?? "",
				email: data["email"] as? String ?? ""
			)
		}
		
		// Filter out blocked users (mutual blocking)
		return await filterUsersFromBlocked(users)
	}
	
	/// Filter out users who are blocked or have blocked current user (mutual blocking)
	@MainActor
	func filterUsersFromBlocked(_ users: [User]) async -> [User] {
		guard let currentUserId = Auth.auth().currentUser?.uid else {
			return users
		}
		
		do {
			try await CYServiceManager.shared.loadCurrentUser()
			let blockedUserIds = Set(CYServiceManager.shared.getBlockedUsers())
			
			// Get unique user IDs to check
			let userIds = Set(users.map { $0.userId })
			
			// Batch fetch user data to check if they've blocked current user
			var usersWhoBlockedCurrentUser: Set<String> = []
			await withTaskGroup(of: (String, Bool).self) { group in
				for userId in userIds {
					group.addTask {
						do {
							let db = Firestore.firestore()
							let userDoc = try await db.collection("users").document(userId).getDocument()
							if let data = userDoc.data(),
							   let userBlockedUsers = data["blockedUsers"] as? [String],
							   userBlockedUsers.contains(currentUserId) {
								return (userId, true)
							}
						} catch {
							print("Error checking if user blocked current user: \(error.localizedDescription)")
						}
						return (userId, false)
					}
				}
				
				for await (userId, isBlocked) in group {
					if isBlocked {
						usersWhoBlockedCurrentUser.insert(userId)
					}
				}
			}
			
			return users.filter { user in
				// Exclude if current user has blocked this user
				if blockedUserIds.contains(user.userId) {
					return false
				}
				// Exclude if this user has blocked current user (mutual blocking)
				if usersWhoBlockedCurrentUser.contains(user.userId) {
					return false
				}
				return true
			}
		} catch {
			print("Error filtering users from blocked: \(error.localizedDescription)")
			return users
		}
	}
	
	func updateUserProfile(userId: String, name: String, username: String, profileImage: UIImage?, backgroundImage: UIImage?) async throws -> AppUser {
		let db = Firestore.firestore()
		var updateData: [String: Any] = [
			"name": name,
			"username": username
		]
		
		var profileImageURL: String?
		var backgroundImageURL: String?
		
		// Upload images to Firebase Storage if provided
		if let profileImage = profileImage {
			let profileURL = try await uploadImage(profileImage, path: "profile_images/\(userId).jpg")
			updateData["profileImageURL"] = profileURL
			profileImageURL = profileURL
		}
		
		if let backgroundImage = backgroundImage {
			let backgroundURL = try await uploadImage(backgroundImage, path: "background_images/\(userId).jpg")
			updateData["backgroundImageURL"] = backgroundURL
			backgroundImageURL = backgroundURL
		}
		
		// Save to Firebase (source of truth)
		try await db.collection("users").document(userId).updateData(updateData)
		
		// Get email and birth info from Firebase
		let firestoreDoc = try await db.collection("users").document(userId).getDocument()
		let firestoreData = firestoreDoc.data() ?? [:]
		let email = firestoreData["email"] as? String ?? ""
		let birthMonth = firestoreData["birthMonth"] as? String ?? ""
		let birthDay = firestoreData["birthDay"] as? String ?? ""
		let birthYear = firestoreData["birthYear"] as? String ?? ""
		
		// Clear cache to force fresh load
		cache[userId] = nil
		
		// Return updated user from Firebase
		return AppUser(
			userId: userId,
			name: name,
			username: username,
			profileImageURL: profileImageURL ?? (firestoreData["profileImageURL"] as? String),
			backgroundImageURL: backgroundImageURL ?? (firestoreData["backgroundImageURL"] as? String),
			birthMonth: birthMonth,
			birthDay: birthDay,
			birthYear: birthYear,
			email: email
		)
	}
	
	private func uploadImage(_ image: UIImage, path: String) async throws -> String {
		// Verify user is authenticated before uploading
		guard Auth.auth().currentUser != nil else {
			throw NSError(domain: "UserService", code: -1, userInfo: [NSLocalizedDescriptionKey: "User must be authenticated to upload images"])
		}
		
		guard let imageData = image.jpegData(compressionQuality: 0.8) else {
			throw NSError(domain: "UserService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to convert image"])
		}
		
		let storage = Storage.storage()
		let ref = storage.reference().child(path)
		let metadata = StorageMetadata()
		metadata.contentType = "image/jpeg"
		
		do {
			_ = try await ref.putDataAsync(imageData, metadata: metadata)
			let url = try await ref.downloadURL()
			return url.absoluteString
		} catch {
			// Provide more detailed error information
			print("❌ Storage upload error for path: \(path)")
			print("   Error: \(error.localizedDescription)")
			if let nsError = error as NSError? {
				print("   Domain: \(nsError.domain), Code: \(nsError.code)")
				print("   UserInfo: \(nsError.userInfo)")
			}
			// Re-throw with more context
			throw NSError(domain: "UserService", code: -1, userInfo: [
				NSLocalizedDescriptionKey: "Failed to upload image: \(error.localizedDescription)",
				NSUnderlyingErrorKey: error
			])
		}
	}

	func completeProfileSetup(name: String,
							  username: String,
							  email: String,
							  birthMonth: String,
							  birthDay: String,
							  birthYear: String,
							  profileImage: UIImage?,
							  backgroundImage: UIImage?) async throws -> Bool {
		guard let userId = Auth.auth().currentUser?.uid else {
			throw UserError.userNotFound
		}
		
		let db = Firestore.firestore()
		// Ensure username is always stored in lowercase for consistent lookup
		let lowercaseUsername = username.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
		
		// CRITICAL FIX: Final username availability check right before save to minimize race condition window
		// This is the last check before we write to Firestore
		let isUsernameAvailable = try await isUsernameAvailable(lowercaseUsername)
		if !isUsernameAvailable {
			// Check if it's the current user updating their profile with the same username
			if let existingUser = try? await getUser(userId: userId),
			   existingUser.username.lowercased() == lowercaseUsername {
				// User already has this username, it's fine to keep it
				print("ℹ️ User already has this username, proceeding with update")
			} else {
				// Username is taken by another user
				throw UserError.usernameTaken
			}
		}
		
		// Now upload images and save data (username availability verified)
		var userData: [String: Any] = [
			"name": name,
			"username": lowercaseUsername,
			"email": email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
			"birthMonth": birthMonth,
			"birthDay": birthDay,
			"birthYear": birthYear,
			"createdAt": Timestamp(date: Date())
		]
		
		// Upload profile image if provided
		if let profileImage = profileImage {
			let profileURL = try await uploadImage(profileImage, path: "profile_images/\(userId).jpg")
			userData["profileImageURL"] = profileURL
			print("✅ Profile image uploaded: \(profileURL)")
		} else {
			userData["profileImageURL"] = ""
		}
		
		// Upload background image if provided
		if let backgroundImage = backgroundImage {
			let backgroundURL = try await uploadImage(backgroundImage, path: "background_images/\(userId).jpg")
			userData["backgroundImageURL"] = backgroundURL
			print("✅ Background image uploaded: \(backgroundURL)")
		} else {
			userData["backgroundImageURL"] = ""
		}
		
		// Save to Firestore with retry logic
		try await FirebaseRetryManager.shared.executeWithRetry(
			operation: {
		try await db.collection("users").document(userId).setData(userData, merge: true)
			},
			operationName: "Save user profile"
		)
		print("✅ User profile saved to Firestore for user: \(userId)")
		
		// Clear cache to force fresh load
		cache[userId] = nil
		
		return true
	}
}

enum UserError: Error {
	case emailTaken
	case usernameTaken
	case userNotFound
}

// Global type alias for User (AppUser)
typealias User = UserService.AppUser

