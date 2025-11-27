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

	func clearUserCache(userId: String) {
		cache[userId] = nil
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
			if snapshot.documents.isEmpty {
				print("⚠️ Username not found with exact match, trying case-insensitive search...")
				// Get a larger batch and filter client-side (less efficient but handles edge cases)
				let allUsersSnapshot = try await withTimeout(seconds: 8) {
					try await db.collection("users")
						.limit(to: 1000) // Reasonable limit
						.getDocuments()
				}
			
			// Filter for case-insensitive match
			for doc in allUsersSnapshot.documents {
				let data = doc.data()
				if let storedUsername = data["username"] as? String,
				   storedUsername.lowercased() == normalizedUsername {
					print("✅ Found user with case-insensitive match")
					return AppUser(
						userId: doc.documentID,
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
			print("✅ Found user: \(doc.documentID), email: \(data["email"] as? String ?? "none")")
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
		} catch is TimeoutError {
			print("⏱️ Username lookup timed out - network may be slow or unavailable")
			throw NSError(domain: "FIRFirestoreErrorDomain", code: 14, userInfo: [NSLocalizedDescriptionKey: "Request timed out. Please check your internet connection."])
		} catch {
			// Re-throw other errors
			throw error
		}
	}

	func getUser(userId: String) async throws -> AppUser? {
		if let cached = cache[userId] { return cached }
		
		// Firebase is source of truth - load from Firebase first
		let db = Firestore.firestore()
		let doc = try await db.collection("users").document(userId).getDocument()
		
		guard let data = doc.data() else { return nil }
		
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
		
		return user
	}
	
	func getAllUsers() async throws -> [User] {
		let db = Firestore.firestore()
		let snapshot = try await db.collection("users").getDocuments()
		
		return snapshot.documents.compactMap { doc in
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
		
		// Save to Firestore
		try await db.collection("users").document(userId).setData(userData, merge: true)
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

